// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// One wallpaper drawn into a view: still image, animated image (display-link driven, capped) or looping muted video.
import AppKit
import AVFoundation
import ImageIO

/// Decoded animation: frame delays are read up front (cheap); frames are decoded on demand at a bounded size
/// and cached only while the whole loop fits the memory budget. One instance is shared by every display
/// that shows the same file at the same decode size (see `shared`), so two screens never decode twice.
final class FrameSequence: @unchecked Sendable {
    let source: CGImageSource
    let count: Int
    let delays: [Double]
    let pixelSize: CGSize
    private let maxPixel: Int
    private let nativeMax: Int
    private let rotated: Bool
    private let cacheAll: Bool
    private let lock = NSLock()
    private var cache: [Int: CGImage] = [:]
    private var users = 0

    static let cacheBudget = 96 * 1024 * 1024

    private static let poolLock = NSLock()
    private static let pool = NSMapTable<NSString, FrameSequence>(keyOptions: .copyIn, valueOptions: .weakMemory)

    /// The decoder for this file at the size a screen of `screenMaxPixel` needs. Reused while any surface still holds it.
    static func shared(url: URL, screenMaxPixel: Int) -> FrameSequence? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let key = "\(url.path)|\(AnimationTiming.decodeMaxPixel(contentMax: max(w, h), screenMax: screenMaxPixel))" as NSString
        poolLock.lock(); defer { poolLock.unlock() }
        if let s = pool.object(forKey: key) { return s }
        guard let s = FrameSequence(source: src, screenMaxPixel: screenMaxPixel) else { return nil }
        pool.setObject(s, forKey: key)
        return s
    }

    private init?(source src: CGImageSource, screenMaxPixel: Int) {
        let n = CGImageSourceGetCount(src)
        guard n > 0, let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        source = src; count = n
        delays = (0..<n).map { Self.delay(src, $0) }
        nativeMax = max(w, h)
        rotated = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) > 1
        let m = AnimationTiming.decodeMaxPixel(contentMax: max(w, h), screenMax: screenMaxPixel)
        maxPixel = m
        let s = min(1, Double(m) / Double(max(w, h)))
        pixelSize = CGSize(width: Double(w) * s, height: Double(h) * s)
        cacheAll = AnimationTiming.canCache(frames: n, width: Int(pixelSize.width), height: Int(pixelSize.height), budgetBytes: Self.cacheBudget)
    }

    /// Decodes one frame. At native size this is the file's own pixels with no resampling at all; the
    /// thumbnail path (which can resample) is only used when the frame has to shrink or be rotated.
    static func decode(_ src: CGImageSource, _ idx: Int, maxPixel: Int, nativeMax: Int, rotated: Bool) -> CGImage? {
        if maxPixel >= nativeMax && !rotated {
            return CGImageSourceCreateImageAtIndex(src, idx, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, idx, opts as CFDictionary)
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

    func cached(_ i: Int) -> CGImage? {
        guard cacheAll else { return nil }
        let idx = ((i % count) + count) % count
        return lock.withLock { cache[idx] }
    }

    func frame(_ i: Int) -> CGImage? {
        let idx = ((i % count) + count) % count
        if cacheAll, let c = lock.withLock({ cache[idx] }) { return c }
        let img = Self.decode(source, idx, maxPixel: maxPixel, nativeMax: nativeMax, rotated: rotated)
        if cacheAll, let img { lock.withLock { cache[idx] = img } }
        return img
    }

    /// A surface starts or stops playing this sequence. The cache is only dropped when nobody plays it.
    func acquire() { lock.withLock { users += 1 } }
    func release() {
        lock.withLock {
            users = max(0, users - 1)
            if users == 0 { cache.removeAll() }
        }
    }
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


/// Display-link target that does not keep the surface alive (a CADisplayLink retains its target).
private final class LinkTarget: NSObject {
    weak var surface: WallpaperSurface?
    @objc func step(_ link: CADisplayLink) { MainActor.assumeIsolated { surface?.step() } }
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

    // Animated-image clock, driven by a per-screen display link.
    private var running = false
    private var holdsSequence = false
    private var elapsedBefore = 0.0
    private var startedAt = 0.0
    private var shownIndex = -1
    private var decoding = false
    private var generation = 0
    private var link: CADisplayLink?
    private let linkTarget = LinkTarget()
    private let decodeQueue = DispatchQueue(label: "HapticGlow.wallpaper.decode", qos: .utility)
    /// The refresh range asked of the panel while an animated image plays (nil for stills and video).
    private(set) var rateRange: CAFrameRateRange?

    init(info: WallpaperInfo, mediaURL: URL, stillURL: URL, fit: WallpaperFit, fpsCap: Int, screenPixels: CGSize) {
        self.info = info; self.mediaURL = mediaURL; self.fit = fit; self.fpsCap = max(1, fpsCap)
        contentPixels = CGSize(width: info.pixelWidth, height: info.pixelHeight)
        let screenMaxPixel = Int(max(screenPixels.width, screenPixels.height))
        super.init(frame: .zero)
        linkTarget.surface = self
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
                let native = max(info.pixelWidth, info.pixelHeight)
                let rotated = (((CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int) ?? 1) > 1
                let img = FrameSequence.decode(src, 0, maxPixel: AnimationTiming.decodeMaxPixel(contentMax: native, screenMax: screenMaxPixel),
                                               nativeMax: native, rotated: rotated) ?? poster
                content.contents = img
                if let img { contentPixels = CGSize(width: img.width, height: img.height) }
            }
        case .animatedImage:
            sequence = FrameSequence.shared(url: mediaURL, screenMaxPixel: screenMaxPixel)
            if let s = sequence {
                contentPixels = s.pixelSize
                rateRange = AnimationTiming.frameRateRange(delays: s.delays, cap: self.fpsCap)
            }
            content.contents = poster
        case .video:
            let item = AVPlayerItem(url: mediaURL)
            // Never decode more than the screen can show; pacing is left to AVPlayerLayer / the panel.
            item.preferredMaximumResolution = screenPixels
            item.preferredPeakBitRate = max(8_000_000, screenPixels.width * screenPixels.height * 4)
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
        content.allowsEdgeAntialiasing = false
        content.edgeAntialiasingMask = []
        content.isHidden = info.kind == .video
        apply(fit: fit)
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { shutdown() }

    private var backing: CGFloat { window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    func apply(fit: WallpaperFit) {
        self.fit = fit
        // Pixel art: nearest neighbour everywhere, so a 960x540 frame on a 3840x2160 panel is exactly 4x.
        let f: CALayerContentsFilter = fit == .pixelArt ? .nearest : .linear
        content.magnificationFilter = f
        content.minificationFilter = f
        playerLayer?.magnificationFilter = f
        playerLayer?.minificationFilter = f
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = backing
        let rect = WallpaperLayout.rect(fit: fit, content: contentPixels, bounds: bounds.size, backing: b)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = b
        content.contentsScale = b
        playerLayer?.contentsScale = b
        content.frame = rect
        playerLayer?.frame = rect
        CATransaction.commit()
    }

    /// The window moved to a screen with another scale (or the mode changed): re-layout and re-attach the display link.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        rebuildLink()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        rebuildLink()
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

    /// Releases the display link, decoder and player. Called when the surface is replaced or the engine stops.
    func shutdown() {
        stopClock()
        link?.invalidate(); link = nil
        player?.pause()
        looper?.disableLooping()
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func makeLink() {
        guard link == nil, window != nil, rateRange != nil else { return }
        let l = displayLink(target: linkTarget, selector: #selector(LinkTarget.step(_:)))
        if let r = rateRange { l.preferredFrameRateRange = r }
        l.isPaused = !running
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func rebuildLink() {
        link?.invalidate(); link = nil
        if running { makeLink() }
    }

    private func startClock() {
        guard !running, let seq = sequence, seq.count > 1 else { return }
        running = true
        startedAt = now()
        generation += 1
        if !holdsSequence { seq.acquire(); holdsSequence = true }
        if link == nil { makeLink() }
        link?.isPaused = false
    }

    private func stopClock() {
        link?.isPaused = true
        guard running else { return }
        running = false
        elapsedBefore += now() - startedAt
        generation += 1
        decoding = false
        if holdsSequence { sequence?.release(); holdsSequence = false }
    }

    /// One display-link tick: show the frame that belongs at this time. Frames only change at the content's own
    /// rate, and the link's preferred range lets ProMotion run the panel slower than its maximum.
    fileprivate func step() {
        guard running, let seq = sequence else { return }
        let t = elapsedBefore + (now() - startedAt)
        let idx = AnimationTiming.frameIndex(at: t, delays: seq.delays)
        guard idx != shownIndex else { return }
        if let img = seq.cached(idx) { show(img, index: idx); return }
        guard !decoding else { return }
        decoding = true
        let gen = generation
        decodeQueue.async { [weak self] in
            let img = seq.frame(idx)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.decoding = false
                    self.show(img, index: idx)
                }
            }
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
