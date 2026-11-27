// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// One wallpaper drawn into a view: still image, animated image (timer driven, capped) or looping muted video.
import AppKit
import AVFoundation
import ImageIO

/// Decoded animation: frame delays are read up front (cheap); frames are decoded on demand at a bounded size
/// and cached only while the whole loop fits the memory budget.
final class FrameSequence: @unchecked Sendable {
    let source: CGImageSource
    let count: Int
    let delays: [Double]
    let pixelSize: CGSize
    private let maxPixel: Int
    private let cacheAll: Bool
    private let lock = NSLock()
    private var cache: [Int: CGImage] = [:]

    static let cacheBudget = 96 * 1024 * 1024

    init?(url: URL, screenMaxPixel: Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0, let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        source = src; count = n
        delays = (0..<n).map { Self.delay(src, $0) }
        let m = AnimationTiming.decodeMaxPixel(contentMax: max(w, h), screenMax: screenMaxPixel)
        maxPixel = m
        let s = min(1, Double(m) / Double(max(w, h)))
        pixelSize = CGSize(width: Double(w) * s, height: Double(h) * s)
        cacheAll = AnimationTiming.canCache(frames: n, width: Int(pixelSize.width), height: Int(pixelSize.height), budgetBytes: Self.cacheBudget)
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)]
        for (d, unclamped, clamped) in dicts {
            guard let dict = p[d] as? [CFString: Any] else { continue }
            if let v = (dict[unclamped] as? Double) ?? (dict[clamped] as? Double) { return AnimationTiming.clampedDelay(v) }
        }
        return 0.1
    }

    func frame(_ i: Int) -> CGImage? {
        let idx = ((i % count) + count) % count
        if cacheAll, let c = lock.withLock({ cache[idx] }) { return c }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        let img = CGImageSourceCreateThumbnailAtIndex(source, idx, opts as CFDictionary)
        if cacheAll, let img { lock.withLock { cache[idx] = img } }
        return img
    }

    func dropCache() { lock.withLock { cache.removeAll() } }
}

enum EdgeColor {
    /// Average colour of the outer ring of the image: used as the letterbox colour.
    static func of(_ image: CGImage) -> CGColor {
        let side = 48
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return CGColor(gray: 0, alpha: 1) }
        var r = 0, g = 0, b = 0, n = 0
        for y in 0..<side { for x in 0..<side where x == 0 || y == 0 || x == side - 1 || y == side - 1 {
            let o = (y * side + x) * 4
            r += Int(px[o]); g += Int(px[o + 1]); b += Int(px[o + 2]); n += 1
        } }
        guard n > 0 else { return CGColor(gray: 0, alpha: 1) }
        return CGColor(srgbRed: CGFloat(r) / CGFloat(n * 255), green: CGFloat(g) / CGFloat(n * 255), blue: CGFloat(b) / CGFloat(n * 255), alpha: 1)
    }
}

@MainActor
final class WallpaperSurface: NSView {
    let info: WallpaperInfo
    private let mediaURL: URL
    private(set) var fit: WallpaperFit
    private let fpsCap: Int
    private let content = CALayer()
    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var sequence: FrameSequence?
    private var poster: CGImage?
    private var contentPixels: CGSize

    // Animated-image clock.
    private var running = false
    private var generation = 0
    private var elapsedBefore = 0.0
    private var startedAt = 0.0
    private var shownIndex = -1
    private let decodeQueue = DispatchQueue(label: "HapticGlow.wallpaper.decode", qos: .utility)

    init(info: WallpaperInfo, mediaURL: URL, stillURL: URL, fit: WallpaperFit, fpsCap: Int, screenMaxPixel: Int) {
        self.info = info; self.mediaURL = mediaURL; self.fit = fit; self.fpsCap = max(1, fpsCap)
        contentPixels = CGSize(width: info.pixelWidth, height: info.pixelHeight)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(content)
        if let src = CGImageSourceCreateWithURL(stillURL as CFURL, nil) {
            poster = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if let poster { layer?.backgroundColor = EdgeColor.of(poster) } else { layer?.backgroundColor = CGColor(gray: 0, alpha: 1) }
        switch info.kind {
        case .image:
            if let src = CGImageSourceCreateWithURL(mediaURL as CFURL, nil) {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceShouldCacheImmediately: true,
                                             kCGImageSourceThumbnailMaxPixelSize: AnimationTiming.decodeMaxPixel(contentMax: max(info.pixelWidth, info.pixelHeight), screenMax: screenMaxPixel)]
                let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? poster
                content.contents = img
                if let img { contentPixels = CGSize(width: img.width, height: img.height) }
            }
        case .animatedImage:
            sequence = FrameSequence(url: mediaURL, screenMaxPixel: screenMaxPixel)
            if let s = sequence { contentPixels = s.pixelSize }
            content.contents = poster
        case .video:
            let item = AVPlayerItem(url: mediaURL)
            let p = AVQueuePlayer()
            p.isMuted = true
            p.volume = 0
            p.allowsExternalPlayback = false
            p.preventsDisplaySleepDuringVideoPlayback = false
            p.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: p, templateItem: item)
            let pl = AVPlayerLayer(player: p)
            pl.videoGravity = .resize
            player = p; playerLayer = pl
            layer?.addSublayer(pl)
        }
        content.contentsGravity = .resize
        content.isHidden = info.kind == .video
        apply(fit: fit)
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { stop() }

    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func apply(fit: WallpaperFit) {
        self.fit = fit
        let nearest = fit == .pixelArt
        content.magnificationFilter = nearest ? .nearest : .linear
        content.minificationFilter = nearest ? .nearest : .linear
        playerLayer?.magnificationFilter = nearest ? .nearest : .linear
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rect = WallpaperLayout.rect(fit: fit, content: contentPixels, bounds: bounds.size, backing: backing)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contentsScale = backing
        content.frame = rect
        playerLayer?.frame = rect
        CATransaction.commit()
    }

    // MARK: Playback

    /// Play, or hold: `showStill` swaps animated images back to the still frame (battery saver).
    func setPlaying(_ play: Bool, showStill: Bool) {
        switch info.kind {
        case .image: return
        case .video:
            if play { player?.play() } else { player?.pause() }
        case .animatedImage:
            if play { startClock() } else {
                stopClock()
                if showStill, shownIndex != -1 { show(poster, index: -1) }
            }
        }
    }

    private func stop() {
        generation += 1
        player?.pause()
        looper?.disableLooping()
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func startClock() {
        guard !running, let seq = sequence, seq.count > 1 else { return }
        running = true
        startedAt = now()
        generation += 1
        tick(generation)
    }

    private func stopClock() {
        guard running else { return }
        running = false
        elapsedBefore += now() - startedAt
        generation += 1
        sequence?.dropCache()
    }

    private func tick(_ gen: Int) {
        guard running, gen == generation, let seq = sequence else { return }
        let t = elapsedBefore + (now() - startedAt)
        let idx = AnimationTiming.frameIndex(at: t, delays: seq.delays)
        let wait = max(AnimationTiming.timeToNextFrame(at: t, delays: seq.delays), 1.0 / Double(fpsCap))
        if idx != shownIndex {
            decodeQueue.async { [weak self] in
                let img = seq.frame(idx)
                DispatchQueue.main.async { MainActor.assumeIsolated { if let self, gen == self.generation { self.show(img, index: idx) } } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, qos: .utility) { [weak self] in
            MainActor.assumeIsolated { self?.tick(gen) }
        }
    }

    private func show(_ image: CGImage?, index: Int) {
        guard let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = image
        CATransaction.commit()
        shownIndex = index
    }

    /// The frame on screen now, for "use this frame as the lock screen still".
    func currentFrame() async -> CGImage? {
        switch info.kind {
        case .image: return poster
        case .animatedImage:
            guard let seq = sequence else { return poster }
            let t = elapsedBefore + (running ? now() - startedAt : 0)
            let idx = AnimationTiming.frameIndex(at: t, delays: seq.delays)
            return await Task.detached { seq.frame(idx) }.value
        case .video:
            guard let item = player?.currentItem else { return poster }
            let gen = AVAssetImageGenerator(asset: item.asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return (try? await gen.image(at: player?.currentTime() ?? .zero).image) ?? poster
        }
    }
}
