// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Renders a library item to a 4K HEVC Main10 .mov loop at 60 fps (plus a preview JPEG) that the lock screen can play as an Aerial.
import Foundation
import AVFoundation
import CoreVideo
import ImageIO
import AppKit
import VideoToolbox

enum LockScreenExportError: Error, LocalizedError {
    case unreadable, writer(String), cancelled
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The wallpaper could not be read for export."
        case .writer(let m): return "Video export failed: \(m)"
        case .cancelled: return "Export was cancelled."
        }
    }
}

enum LockScreenExporter {
    /// The loop runs at least this long, repeating the animation; capped so files stay small and export quickly.
    static let minSeconds = 20.0
    static let maxSeconds = 60.0
    /// 4K 10-bit HEVC at 60 fps with a 30 fps base temporal sub-layer (plays cleanly across lock/unlock cycles on macOS 26/27).
    static let canvas = CGSize(width: 3840, height: 2160)
    static let fps: Int64 = 60

    /// How many times to repeat an animation of `length` seconds so the loop is 20 to 60 s long.
    static func repeats(length: Double) -> Int {
        guard length > 0 else { return 1 }
        let n = Int((minSeconds / length).rounded(.up))
        let capped = max(1, Int((maxSeconds / length).rounded(.down)))
        return max(1, min(n, capped))
    }

    /// Even pixel size of the screen the loop is meant for (only its aspect ratio matters).
    static func targetSize(screen: NSScreen?) -> CGSize {
        guard let s = screen else { return canvas }
        let w = Int((s.frame.width * s.backingScaleFactor).rounded()), h = Int((s.frame.height * s.backingScaleFactor).rounded())
        return CGSize(width: max(2, w & ~1), height: max(2, h & ~1))
    }

    /// The part of the 3840x2160 canvas that stays visible once macOS fills a screen of `screen`'s aspect ratio
    /// (aspect fill crops the rest). The picture is laid out inside it, so nothing important is cropped away.
    static func visibleRegion(screen: CGSize) -> CGRect {
        let aspect = screen.height > 0 ? screen.width / screen.height : canvas.width / canvas.height
        var w = canvas.width, h = canvas.height
        if aspect < w / h { w = (h * aspect).rounded() } else { h = (w / aspect).rounded() }
        w = CGFloat(Int(w) & ~1); h = CGFloat(Int(h) & ~1)
        return CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)
    }

    /// Writes `<id>.mov` and `<id>.jpg` into `dir`. `size` is the target screen's pixel size. Heavy work: call off the main thread.
    static func export(item: WallpaperInfo, mediaURL: URL, fit: WallpaperFit, size: CGSize, id: String, into dir: URL) async throws -> (mov: URL, jpg: URL) {
        let mov = dir.appendingPathComponent("\(id).mov"), jpg = dir.appendingPathComponent("\(id).jpg")
        try? FileManager.default.removeItem(at: mov)
        let region = visibleRegion(screen: size)
        switch item.kind {
        case .video: try await exportVideo(mediaURL, fit: fit, region: region, to: mov)
        case .animatedImage, .image: try await exportImages(mediaURL, fit: fit, region: region, to: mov, jpg: jpg, animated: item.kind == .animatedImage)
        }
        if item.kind == .video { try await videoPreview(mov, region: region, to: jpg) }
        return (mov, jpg)
    }

    // MARK: Writer

    /// Produces the pixel buffer to show at each tick, in order, then nil.
    private typealias Feed = (CVPixelBufferPool?) throws -> (buffer: CVPixelBuffer, tick: Int64)?

    private final class SendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static func write(to mov: URL, ticks total: Int64, makeFeed: @escaping @Sendable () throws -> Feed) async throws {
        try await Task.detached(priority: .utility) {
            try encodeBlocking(to: mov, ticks: total, makeFeed: makeFeed)
        }.value
    }

    private static func encodeBlocking(to mov: URL, ticks total: Int64, makeFeed: () throws -> Feed) throws {
        let w = Int32(canvas.width), h = Int32(canvas.height)
        let writer = try AVAssetWriter(outputURL: mov, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw LockScreenExportError.writer("cannot add video input") }
        writer.add(input)

        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        let srcAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(w),
            kCVPixelBufferHeightKey: Int(h),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var sessionRef: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: w, height: h,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: srcAttrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &sessionRef
        )
        guard createStatus == noErr, let session = sessionRef else {
            throw LockScreenExportError.writer("VTCompressionSessionCreate failed (\(createStatus))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        func setProp(_ key: CFString, _ val: CFTypeRef) -> OSStatus {
            VTSessionSetProperty(session, key: key, value: val)
        }
        _ = setProp(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        _ = setProp(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
        _ = setProp(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = setProp(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        _ = setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps))
        _ = setProp(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1.0))
        _ = setProp(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 16_000_000))
        _ = setProp(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        _ = setProp(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        _ = setProp(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        // Required by WallpaperAerialsExtension: split the HEVC stream into two temporal sub-layers
        // (base layer at half rate + enhancement layer), producing tscl/tsas boxes and VPS sub-layer syntax.
        _ = setProp("NumberOfTemporalLayers" as CFString, NSNumber(value: 2))
        let blStatus = setProp(kVTCompressionPropertyKey_BaseLayerFrameRateFraction, NSNumber(value: 0.5))
        if blStatus != noErr {
            _ = setProp(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: Double(fps) * 0.5))
        }

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepStatus == noErr else {
            throw LockScreenExportError.writer("VTCompressionSessionPrepareToEncodeFrames failed (\(prepStatus))")
        }

        guard writer.startWriting() else {
            throw LockScreenExportError.writer(writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let appendQueue = DispatchQueue(label: "HapticGlow.lockscreen.append")
        let lock = NSLock()
        var encodeError: Error?
        var didFail = false
        let inFlight = DispatchSemaphore(value: 12)
        let inputBox = SendableBox(input)
        let writerBox = SendableBox(writer)

        let pool = VTCompressionSessionGetPixelBufferPool(session)
        let feed = try makeFeed()
        let duration = CMTime(value: 1, timescale: Int32(fps))

        while true {
            if let err = lock.withLock({ encodeError }) { throw err }
            let next = try feed(pool)
            guard let n = next else { break }

            inFlight.wait()
            let pts = CMTime(value: n.tick, timescale: Int32(fps))
            var flagsOut = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: n.buffer, presentationTimeStamp: pts,
                duration: duration, frameProperties: nil, infoFlagsOut: &flagsOut
            ) { encStatus, _, sampleBuffer in
                defer { inFlight.signal() }
                guard encStatus == noErr else {
                    lock.withLock { if encodeError == nil { encodeError = LockScreenExportError.writer("encode failed (\(encStatus))") } }
                    return
                }
                guard let sb = sampleBuffer else { return }
                let sbBox = SendableBox(sb)
                appendQueue.sync {
                    if lock.withLock({ didFail || encodeError != nil }) { return }
                    let inp = inputBox.value
                    let wr = writerBox.value
                    while !inp.isReadyForMoreMediaData {
                        if wr.status == .failed || wr.status == .cancelled { break }
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                    if !inp.append(sbBox.value) {
                        lock.withLock {
                            didFail = true
                            encodeError = LockScreenExportError.writer(wr.error?.localizedDescription ?? "append sample failed")
                        }
                    }
                }
            }
            if status != noErr {
                inFlight.signal()
                throw LockScreenExportError.writer("VTCompressionSessionEncodeFrame failed (\(status))")
            }
        }

        let completeStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if completeStatus != noErr {
            throw LockScreenExportError.writer("VTCompressionSessionCompleteFrames failed (\(completeStatus))")
        }
        appendQueue.sync {}
        if let err = lock.withLock({ encodeError }) {
            input.markAsFinished()
            writer.cancelWriting()
            throw err
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: total, timescale: Int32(fps)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw LockScreenExportError.writer(writer.error?.localizedDescription ?? "finish failed")
        }
    }

    // MARK: Images and GIF/APNG/WebP

    private static func exportImages(_ url: URL, fit: WallpaperFit, region: CGRect, to mov: URL, jpg: URL, animated: Bool) async throws {
        // Native frames: nothing is resampled before the (nearest-neighbour for pixel art) fit to the video size.
        guard let seq = FrameSequence.shared(url: url, screenMaxPixel: 100_000) else { throw LockScreenExportError.unreadable }
        let delays = animated && seq.count > 1 ? seq.delays : [maxSeconds]
        let length = delays.reduce(0, +)
        let reps = animated && seq.count > 1 ? repeats(length: length) : 1
        guard let first = seq.frame(0) else { throw LockScreenExportError.unreadable }
        let edge = EdgeColor.of(first)

        // One start tick per source frame, held for its own delay: GIF timing is kept to 1/60 s.
        var starts: [(index: Int, tick: Int64)] = []
        var t = 0.0
        for _ in 0..<reps { for (i, d) in delays.enumerated() { starts.append((i, Int64((t * Double(fps)).rounded()))); t += max(d, 1.0 / Double(fps)) } }
        let total = Int64((t * Double(fps)).rounded())
        let startsCopy = starts
        try await write(to: mov, ticks: total) {
            var tick: Int64 = 0, p = 0, shown = -1
            var buf: CVPixelBuffer?
            return { pool in
                guard tick < total else { return nil }
                while p + 1 < startsCopy.count && startsCopy[p + 1].tick <= tick { p += 1 }
                if p != shown {
                    let pb = try makePixelBuffer(pool: pool)
                    guard let frame = seq.frame(startsCopy[p].index), render(frame, into: pb, fit: fit, region: region, edge: edge) else {
                        throw LockScreenExportError.writer("frame \(startsCopy[p].index) could not be drawn")
                    }
                    buf = pb; shown = p
                }
                defer { tick += 1 }
                return (buf!, tick)
            }
        }
        if let img = StillComposer.compose(still: first, fit: fit, pixelSize: region.size, backing: 1, edge: edge),
           let small = WallpaperLibrary.downsample(img, maxPixel: 1920) {
            WallpaperLibrary.writeJPEG(small, to: jpg)
        }
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            CVPixelBufferCreate(kCFAllocatorDefault, Int(canvas.width), Int(canvas.height),
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        }
        guard let pb else { throw LockScreenExportError.writer("no pixel buffer") }
        return pb
    }

    /// Edge colour over the whole canvas, then the picture laid out inside the visible region.
    private static func render(_ frame: CGImage, into pb: CVPixelBuffer, fit: WallpaperFit, region: CGRect, edge: CGColor) -> Bool {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        ctx.setFillColor(edge)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.translateBy(x: region.minX, y: region.minY)
        StillComposer.draw(frame, into: ctx, fit: fit, pixelSize: region.size, backing: 1, edge: edge)
        return true
    }

    // MARK: Video items

    private static func exportVideo(_ url: URL, fit: WallpaperFit, region: CGRect, to mov: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LockScreenExportError.unreadable }
        let (duration, natural, transform, nominal) = try await (
            asset.load(.duration), track.load(.naturalSize), track.load(.preferredTransform), track.load(.nominalFrameRate)
        )
        guard duration.seconds > 0 else { throw LockScreenExportError.unreadable }
        let clip = CMTime(seconds: min(duration.seconds, maxSeconds), preferredTimescale: 600)
        let repCount = repeats(length: clip.seconds)
        let totalClipDuration = CMTimeMultiply(clip, multiplier: Int32(repCount))
        let total = Int64((totalClipDuration.seconds * Double(fps)).rounded())
        let srcFps = max(24, min(Int32(nominal > 0 ? nominal.rounded() : 30), 60))

        try await write(to: mov, ticks: total) {
            let syncAsset = AVURLAsset(url: url)
            guard let syncTrack = syncAsset.tracks(withMediaType: .video).first else { throw LockScreenExportError.unreadable }
            let comp = AVMutableComposition()
            guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw LockScreenExportError.unreadable
            }
            var at = CMTime.zero
            for _ in 0..<repCount {
                try ct.insertTimeRange(CMTimeRange(start: .zero, duration: clip), of: syncTrack, at: at)
                at = CMTimeAdd(at, clip)
            }
            // Fit with the same rules as the live wallpaper: scale and position the (rotated) frame inside the visible region.
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            let r = WallpaperLayout.rect(fit: fit, content: shown.size, bounds: region.size, backing: 1)
            let k = CGAffineTransform(scaleX: r.width / shown.width, y: r.height / shown.height)
            let place = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY)).concatenating(k)
                .concatenating(CGAffineTransform(translationX: region.minX + r.minX, y: region.minY + r.minY))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
            layer.setTransform(place, at: .zero)
            let instr = AVMutableVideoCompositionInstruction()
            instr.timeRange = CMTimeRange(start: .zero, duration: at)
            instr.layerInstructions = [layer]
            instr.backgroundColor = CGColor(gray: 0, alpha: 1)
            let vc = AVMutableVideoComposition()
            vc.renderSize = canvas
            vc.frameDuration = CMTime(value: 1, timescale: srcFps)
            vc.instructions = [instr]
            let reader = try AVAssetReader(asset: comp)
            let out = AVAssetReaderVideoCompositionOutput(videoTracks: [ct], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.videoComposition = vc
            guard reader.canAdd(out) else { throw LockScreenExportError.unreadable }
            reader.add(out)
            guard reader.startReading() else { throw LockScreenExportError.writer(reader.error?.localizedDescription ?? "cannot read the video") }

            func pull() -> (CVPixelBuffer, Int64)? {
                guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
                return (pb, Int64((CMSampleBufferGetPresentationTimeStamp(sb).seconds * Double(fps)).rounded()))
            }
            // Each decoded frame is held until the next one is due, so 24/30/60 fps video lands on the 60 fps timeline.
            var tick: Int64 = 0
            var cur: (CVPixelBuffer, Int64)?
            var upcoming = pull()
            return { _ in
                guard tick < total else { return nil }
                while let n = upcoming, n.1 <= tick { cur = n; upcoming = pull() }
                guard let c = cur else { throw LockScreenExportError.writer("the video has no frame at the start") }
                defer { tick += 1 }
                return (c.0, tick)
            }
        }
    }

    private static func videoPreview(_ mov: URL, region: CGRect, to jpg: URL) async throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: mov))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 3840, height: 3840)
        let img = try await gen.image(at: .zero).image
        let visible = img.cropping(to: region) ?? img
        WallpaperLibrary.writeJPEG(WallpaperLibrary.downsample(visible, maxPixel: 1920) ?? visible, to: jpg)
    }
}
