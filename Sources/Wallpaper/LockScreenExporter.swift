// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Renders a library item to an HEVC .mov loop (plus a preview JPEG) that the lock screen can play as an Aerial.
import Foundation
import AVFoundation
import CoreVideo
import ImageIO
import AppKit

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
    /// The loop runs at least this long, repeating the animation; capped so files stay small.
    static let minSeconds = 30.0
    static let maxSeconds = 60.0

    /// How many times to repeat an animation of `length` seconds so the loop is 30 to 60 s long.
    static func repeats(length: Double) -> Int {
        guard length > 0 else { return 1 }
        let n = Int((minSeconds / length).rounded(.up))
        let capped = max(1, Int((maxSeconds / length).rounded(.down)))
        return max(1, min(n, capped))
    }

    /// Even pixel size for the encoder: the main screen's native size, else 3840x2160.
    static func targetSize(screen: NSScreen?) -> CGSize {
        guard let s = screen else { return CGSize(width: 3840, height: 2160) }
        let w = Int((s.frame.width * s.backingScaleFactor).rounded()), h = Int((s.frame.height * s.backingScaleFactor).rounded())
        return CGSize(width: max(2, w & ~1), height: max(2, h & ~1))
    }

    /// Writes `<id>.mov` and `<id>.jpg` into `dir`. Heavy work: call off the main thread.
    static func export(item: WallpaperInfo, mediaURL: URL, fit: WallpaperFit, size: CGSize, id: String, into dir: URL) async throws -> (mov: URL, jpg: URL) {
        let mov = dir.appendingPathComponent("\(id).mov"), jpg = dir.appendingPathComponent("\(id).jpg")
        try? FileManager.default.removeItem(at: mov)
        switch item.kind {
        case .video: try await exportVideo(mediaURL, fit: fit, size: size, to: mov)
        case .animatedImage, .image: try await exportImages(mediaURL, fit: fit, size: size, to: mov, jpg: jpg, animated: item.kind == .animatedImage)
        }
        if item.kind == .video { try await videoPreview(mov, to: jpg) }
        return (mov, jpg)
    }

    // MARK: Images and GIF/APNG/WebP

    private static func exportImages(_ url: URL, fit: WallpaperFit, size: CGSize, to mov: URL, jpg: URL, animated: Bool) async throws {
        // Native frames: nothing is resampled before the (nearest-neighbour for pixel art) fit to the video size.
        guard let seq = FrameSequence.shared(url: url, screenMaxPixel: 100_000) else { throw LockScreenExportError.unreadable }
        let delays = animated && seq.count > 1 ? seq.delays : [LockScreenExporter.minSeconds]
        let length = delays.reduce(0, +)
        let reps = animated && seq.count > 1 ? repeats(length: length) : 1
        let w = Int(size.width), h = Int(size.height)
        guard let first = seq.frame(0) else { throw LockScreenExportError.unreadable }
        let edge = EdgeColor.of(first)

        let writer = try AVAssetWriter(outputURL: mov, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: hevcSettings(w, h))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        guard writer.canAdd(input) else { throw LockScreenExportError.writer("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw LockScreenExportError.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        // One sample per source frame, held for its own delay: GIF timing is kept exactly.
        var samples: [(index: Int, time: Double)] = []
        var t = 0.0
        for _ in 0..<reps { for (i, d) in delays.enumerated() { samples.append((i, t)); t += d } }
        let total = t
        let queue = DispatchQueue(label: "HapticGlow.lockscreen.export")
        var next = 0
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if next >= samples.count {
                        finished = true
                        input.markAsFinished()
                        writer.endSession(atSourceTime: CMTime(seconds: total, preferredTimescale: 6000))
                        writer.finishWriting {
                            if writer.status == .completed { cont.resume() }
                            else { cont.resume(throwing: LockScreenExportError.writer(writer.error?.localizedDescription ?? "finish failed")) }
                        }
                        return
                    }
                    let s = samples[next]; next += 1
                    guard let pool = adaptor.pixelBufferPool else { finished = true; cont.resume(throwing: LockScreenExportError.writer("no pixel buffer pool")); return }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let pb, let frame = seq.frame(s.index), render(frame, into: pb, fit: fit, size: size, edge: edge),
                          adaptor.append(pb, withPresentationTime: CMTime(seconds: s.time, preferredTimescale: 6000)) else {
                        finished = true
                        input.markAsFinished()
                        writer.cancelWriting()
                        cont.resume(throwing: LockScreenExportError.writer(writer.error?.localizedDescription ?? "frame \(s.index) failed"))
                        return
                    }
                }
            }
        }
        if let img = composeImage(first, fit: fit, size: size, edge: edge), let small = WallpaperLibrary.downsample(img, maxPixel: 1920) {
            WallpaperLibrary.writeJPEG(small, to: jpg)
        }
    }

    private static func render(_ frame: CGImage, into pb: CVPixelBuffer, fit: WallpaperFit, size: CGSize, edge: CGColor) -> Bool {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        StillComposer.draw(frame, into: ctx, fit: fit, pixelSize: size, backing: 1, edge: edge)
        return true
    }

    private static func composeImage(_ frame: CGImage, fit: WallpaperFit, size: CGSize, edge: CGColor) -> CGImage? {
        StillComposer.compose(still: frame, fit: fit, pixelSize: size, backing: 1, edge: edge)
    }

    private static func hevcSettings(_ w: Int, _ h: Int) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
         AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoAllowFrameReorderingKey: false,
                                           AVVideoExpectedSourceFrameRateKey: 30],
         AVVideoEncoderSpecificationKey: ["EnableHardwareAcceleratedVideoEncoder": true]]
    }

    // MARK: Video items

    private static func exportVideo(_ url: URL, fit: WallpaperFit, size: CGSize, to mov: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LockScreenExportError.unreadable }
        let (duration, natural, transform) = try await (asset.load(.duration), track.load(.naturalSize), track.load(.preferredTransform))
        guard duration.seconds > 0 else { throw LockScreenExportError.unreadable }
        let comp = AVMutableComposition()
        guard let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw LockScreenExportError.unreadable }
        var at = CMTime.zero
        for _ in 0..<repeats(length: duration.seconds) {
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: at)
            at = CMTimeAdd(at, duration)
        }
        // Fit with the same rules as the live wallpaper: scale and position the (rotated) frame inside the video size.
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let r = WallpaperLayout.rect(fit: fit, content: shown.size, bounds: size, backing: 1)
        let k = CGAffineTransform(scaleX: r.width / shown.width, y: r.height / shown.height)
        let place = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY)).concatenating(k)
            .concatenating(CGAffineTransform(translationX: r.minX, y: size.height - r.maxY))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
        layer.setTransform(place, at: .zero)
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: at)
        instr.layerInstructions = [layer]
        instr.backgroundColor = CGColor(gray: 0, alpha: 1)
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.instructions = [instr]
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality) else { throw LockScreenExportError.writer("no HEVC export session") }
        session.videoComposition = vc
        session.shouldOptimizeForNetworkUse = false
        try await session.export(to: mov, as: .mov)
    }

    private static func videoPreview(_ mov: URL, to jpg: URL) async throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: mov))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        let img = try await gen.image(at: .zero).image
        WallpaperLibrary.writeJPEG(img, to: jpg)
    }
}
