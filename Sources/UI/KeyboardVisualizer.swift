// Live MacBook Pro / MacBook Air keyboard: authentic Apple Silicon 14.5u proportions, black keys,
// white backlit legends with subtle halo and under-key light bleed driven by perceived
// GlowEngine.shared.currentLevel (sqrt) + KeyBus per-key flashes, single Canvas compositing cached
// layer images (plus per-key flash/press sprites), capped at 30 fps in power saver and paused when hidden or steady.
import SwiftUI
import AppKit
import CoreImage

// MARK: - Geometry

struct VizLayout {
    static let pad: CGFloat = 0.24
    static let tpGap: CGFloat = 0.52
    static let tpW: CGFloat = 6.2
    static let tpH: CGFloat = 3.0

    let scale: CGFloat
    let origin: CGPoint
    let trackpad: Bool
    let kind: MacKeyboardKind

    static func boardW(kind: MacKeyboardKind) -> CGFloat { KeyLayout.boardSize(for: kind).width + 2 * pad }
    static func boardH(kind: MacKeyboardKind) -> CGFloat { KeyLayout.boardSize(for: kind).height + 2 * pad }
    static func worldSize(trackpad: Bool, kind: MacKeyboardKind = KeyLayout.kind) -> CGSize {
        CGSize(width: boardW(kind: kind), height: boardH(kind: kind) + (trackpad ? tpGap + tpH : 0))
    }
    static func aspect(trackpad: Bool, kind: MacKeyboardKind = KeyLayout.kind) -> CGFloat {
        let w = worldSize(trackpad: trackpad, kind: kind)
        return w.width / w.height
    }

    init(size: CGSize, trackpad: Bool, kind: MacKeyboardKind = KeyLayout.kind) {
        let w = VizLayout.worldSize(trackpad: trackpad, kind: kind)
        scale = max(1, min(size.width / w.width, size.height / w.height))
        origin = CGPoint(x: (size.width - w.width * scale) / 2, y: (size.height - w.height * scale) / 2)
        self.trackpad = trackpad
        self.kind = kind
    }

    var boardRect: CGRect {
        CGRect(x: origin.x, y: origin.y,
               width: VizLayout.boardW(kind: kind) * scale,
               height: VizLayout.boardH(kind: kind) * scale)
    }

    var trackpadRect: CGRect {
        let bw = VizLayout.boardW(kind: kind)
        let bh = VizLayout.boardH(kind: kind)
        return CGRect(x: origin.x + (bw - VizLayout.tpW) / 2 * scale,
                      y: origin.y + (bh + VizLayout.tpGap) * scale,
                      width: VizLayout.tpW * scale, height: VizLayout.tpH * scale)
    }

    /// Keycap rect in points with Apple chiclet spacing (and tight inner split on inverted-T arrows).
    func rect(_ cap: KeyCap) -> CGRect {
        let r = cap.rect
        let gx = scale * 0.068
        let topGap: CGFloat
        let botGap: CGFloat
        if cap.kind == .arrow {
            // Up arrow sits at row-5 top (+0); Left/Down/Right sit at bottom (+0.5).
            if cap.keyCode == 126 {
                topGap = scale * 0.068
                botGap = scale * 0.032
            } else {
                topGap = scale * 0.032
                botGap = scale * 0.068
            }
        } else {
            topGap = scale * 0.068
            botGap = scale * 0.068
        }
        return CGRect(x: origin.x + (VizLayout.pad + r.minX) * scale + gx,
                      y: origin.y + (VizLayout.pad + r.minY) * scale + topGap,
                      width: max(2, r.width * scale - 2 * gx),
                      height: max(2, r.height * scale - topGap - botGap))
    }

    func cap(at p: CGPoint) -> KeyCap? {
        let padHit = scale * 0.068
        for c in KeyLayout.caps(for: kind) where rect(c).insetBy(dx: -padHit, dy: -padHit).contains(p) {
            return c
        }
        return nil
    }
}

// MARK: - Window visibility probe

struct WindowVisibilityProbe: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            clearObservers()
            guard let win = window else {
                report(false)
                return
            }
            let nc = NotificationCenter.default
            let names: [NSNotification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                tokens.append(nc.addObserver(forName: name, object: win, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(nc.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
            evaluate()
        }

        private func clearObservers() {
            let nc = NotificationCenter.default
            for t in tokens { nc.removeObserver(t) }
            tokens.removeAll()
        }

        private func evaluate() {
            guard let win = window else { report(false); return }
            let visible = !NSApp.isHidden && !win.isMiniaturized && win.isVisible && win.occlusionState.contains(.visible)
            report(visible)
        }

        private func report(_ v: Bool) {
            guard lastReported != v else { return }
            lastReported = v
            onChange?(v)
        }

        deinit {
            let nc = NotificationCenter.default
            for t in tokens { nc.removeObserver(t) }
        }
    }
}

// MARK: - Model (only `isAnimating` and `saver` are observed by SwiftUI; frames never trigger body invalidation)

@MainActor
@Observable
final class KeyboardVizModel {
    struct Flash { var keyCode: UInt16 = 0; var t0: Double = -100; var amp: Float = 0 }
    struct Press { var code: UInt16; var down: Double; var up: Double }   // up < 0 while held

    /// Observable flag that pauses/resumes the TimelineView only on state transitions.
    private(set) var isAnimating = true
    /// Mirrors `PowerState.shared.saver` so TimelineView caps at 30 fps on battery / Low Power Mode.
    private(set) var saver = PowerState.shared.saver

    final class SharedInputBuffer: @unchecked Sendable {
        private let lock = UnfairLock()
        private var flashes = [Flash](repeating: Flash(), count: 16)
        private var flashHead = 0
        private var presses: [Press] = {
            var a = [Press]()
            a.reserveCapacity(16)
            return a
        }()

        func handle(_ e: KeyEvent) -> Bool {
            lock.withLock {
                if e.down {
                    if !e.isRepeat {
                        flashes[flashHead] = Flash(keyCode: e.keyCode, t0: e.time, amp: 1.0)
                        flashHead = (flashHead + 1) % flashes.count
                    }
                    if let i = presses.firstIndex(where: { $0.code == e.keyCode }) {
                        presses[i].down = e.time; presses[i].up = -1
                    } else {
                        presses.append(Press(code: e.keyCode, down: e.time, up: -1))
                    }
                    return true
                } else if let i = presses.firstIndex(where: { $0.code == e.keyCode }) {
                    presses[i].up = e.time
                    return true
                }
                return false
            }
        }

        func triggerKey(_ keyCode: UInt16, now: Double) {
            lock.withLock {
                flashes[flashHead] = Flash(keyCode: keyCode, t0: now, amp: 1.0)
                flashHead = (flashHead + 1) % flashes.count
            }
        }

        func hasActiveInput(now: Double) -> Bool {
            lock.withLock {
                presses.removeAll { $0.up < 0 && now - $0.down > 5 }
                return !presses.isEmpty || flashes.contains { now - $0.t0 < 0.36 && now >= $0.t0 - 0.02 }
            }
        }

        func snapshot(now: Double, activeFlashes: inout [Flash], activePresses: inout [Press]) {
            activeFlashes.removeAll(keepingCapacity: true)
            activePresses.removeAll(keepingCapacity: true)
            lock.withLock {
                for f in flashes where now - f.t0 < 0.36 && now >= f.t0 - 0.02 { activeFlashes.append(f) }
                presses.removeAll { ($0.up >= 0 && now - $0.up > 0.3) || ($0.up < 0 && now - $0.down > 5) }
                activePresses.append(contentsOf: presses)
            }
        }
    }

    @ObservationIgnored private let input = SharedInputBuffer()
    @ObservationIgnored private var keyToken: Int?
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    // Lifecycle / watchdog (main thread only)
    @ObservationIgnored private var isViewVisible = true
    @ObservationIgnored private var isWindowVisible = true
    @ObservationIgnored private var watchTimer: DispatchSourceTimer?
    @ObservationIgnored private var style: KeyboardVisualizer.Style = .glow
    @ObservationIgnored private var showTrackpad = false
    @ObservationIgnored private var previewLevel: Float?
    @ObservationIgnored private var lastTarget: Float = -1
    @ObservationIgnored private var lastHitTime: Double = 0
    @ObservationIgnored private var lastActivityTime: Double = hostNow()

    // Per-frame scratch (main thread only, reused with zero allocations)
    @ObservationIgnored var activeFlashes: [Flash] = []
    @ObservationIgnored var activePresses: [Press] = []
    @ObservationIgnored var lit: [Float] = []
    @ObservationIgnored var pressAmounts: [Float] = []
    @ObservationIgnored var level: Float = 0
    @ObservationIgnored var lastT: Double = 0
    @ObservationIgnored var hoverID: Int?
    @ObservationIgnored private var timerMs: Int = 50

    // Cached geometry, Paths & rasterized layer images (main thread only)
    @ObservationIgnored var cache: VizCache?

    struct CacheKey: Equatable {
        var widthPx: Int
        var heightPx: Int
        var displayScale: CGFloat
        var trackpad: Bool
        var kind: MacKeyboardKind
        var isDark: Bool
    }

    struct BleedSpriteKey: Hashable {
        var widthHalfPt: Int
        var heightHalfPt: Int
        var radiusHalfPt: Int
    }

    struct BleedSprite {
        var image: Image
        var pad: CGFloat
    }

    struct KeySprite {
        var image: Image
        var drawRect: CGRect
    }

    struct VizCache {
        var key: CacheKey
        var size: CGSize
        var trackpad: Bool
        var kind: MacKeyboardKind
        var isDark: Bool
        var scale: CGFloat
        var origin: CGPoint
        var fullRect: CGRect
        var boardRect: CGRect
        var boardClipRect: CGRect
        var boardPath: Path
        var trackpadRect: CGRect
        var trackpadPath: Path
        var caps: [KeyCap]
        var keyRects: [CGRect]
        var keyPaths: [Path]
        var keyRadius: CGFloat
        var touchIDOuterPath: Path?
        var touchIDInnerPath: Path?
        var indexByCode: [UInt16: Int]

        // Consolidated cached layers (max 3 image composites per frame: base + lit overlay + halo)
        var staticBaseImage: Image
        var litOverlayImage: Image
        var haloImage: Image?
        var bleedStrength: Double
        var bleedSprites: [BleedSpriteKey: BleedSprite]
        var keyBleedKeys: [BleedSpriteKey]
        var keyLegendSprites: [KeySprite?]
        var keyHaloSprites: [KeySprite?]
    }

    private static var sharedCaches: [VizCache] = []

    init() {
        activeFlashes.reserveCapacity(16)
        activePresses.reserveCapacity(16)
        lit.reserveCapacity(80)
        pressAmounts.reserveCapacity(80)
        powerObserver = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSaver() }
        }
    }

    private func refreshSaver() {
        let s = PowerState.shared.saver
        if s != saver { saver = s }
        if watchTimer != nil { ensureTimerIfNeeded() }
    }

    func configure(style: KeyboardVisualizer.Style, showTrackpad: Bool, previewLevel: Float?) {
        self.style = style
        self.showTrackpad = showTrackpad
        self.previewLevel = previewLevel
    }

    func start() {
        if keyToken == nil {
            let buf = input
            keyToken = KeyBus.shared.subscribe { [weak self] e in
                if buf.handle(e) {
                    DispatchQueue.main.async { [weak self] in self?.wake() }
                }
            }
        }
        isViewVisible = true
        refreshSaver()
        updateVisibility()
    }

    func stop() {
        if let t = keyToken { KeyBus.shared.unsubscribe(t); keyToken = nil }
        isViewVisible = false
        updateVisibility()
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        updateVisibility()
    }

    private var effectiveVisible: Bool { isViewVisible && isWindowVisible }

    private func updateVisibility() {
        if !effectiveVisible {
            stopTimer()
            if isAnimating { isAnimating = false }
            return
        }
        lastActivityTime = hostNow()
        if !isAnimating { isAnimating = true }
        ensureTimerIfNeeded()
    }

    func wake() {
        lastActivityTime = hostNow()
        guard effectiveVisible else { return }
        if !isAnimating { isAnimating = true }
        ensureTimerIfNeeded()
    }

    private func ensureTimerIfNeeded() {
        guard effectiveVisible else { stopTimer(); return }
        let needsMonitor = (style == .glow && previewLevel == nil) || showTrackpad || isAnimating
        guard needsMonitor else { stopTimer(); return }
        let ms = saver ? 100 : 50
        if let t = watchTimer {
            if ms != timerMs {
                timerMs = ms
                t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(ms / 4))
            }
            return
        }
        timerMs = ms
        let t = DispatchSource.makeTimerSource(flags: [], queue: .main)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(ms / 4))
        t.setEventHandler { [weak self] in self?.pollActivity() }
        watchTimer = t
        t.resume()
    }

    private func stopTimer() {
        watchTimer?.cancel()
        watchTimer = nil
    }

    private func pollActivity() {
        guard effectiveVisible else {
            stopTimer()
            if isAnimating { isAnimating = false }
            return
        }
        let now = hostNow()
        let raw: Float = previewLevel ?? (style == .glow ? GlowEngine.shared.currentLevel : 0)
        let target = raw <= 0 ? 0 : sqrtf(min(1, max(0, raw)))
        var changed = abs(target - lastTarget) > 0.0005 || abs(target - level) > 0.0015
        if showTrackpad {
            let hitT = HapticBus.shared.lastHit().time
            if hitT != lastHitTime {
                lastHitTime = hitT
                changed = true
            }
            if hitT > 0 && now - hitT < 0.65 { changed = true }
        }
        let hasInput = input.hasActiveInput(now: now)
        if changed || hasInput {
            lastTarget = target
            lastActivityTime = now
            if !isAnimating { isAnimating = true; ensureTimerIfNeeded() }
            return
        }
        if isAnimating && now - lastActivityTime > 0.12 {
            isAnimating = false
            if (style == .sounds || previewLevel != nil) && !showTrackpad { stopTimer() } else { ensureTimerIfNeeded() }
        }
    }

    deinit {
        if let t = keyToken { KeyBus.shared.unsubscribe(t) }
        if let o = powerObserver { NotificationCenter.default.removeObserver(o) }
        watchTimer?.cancel()
    }

    /// Trigger a short flash for a specific keycode (interactive tap or KeyTrigger).
    func triggerKey(_ keyCode: UInt16, now: Double) {
        input.triggerKey(keyCode, now: now)
        wake()
    }

    /// Copy live flashes and presses into scratch arrays.
    func snapshot(now: Double) {
        input.snapshot(now: now, activeFlashes: &activeFlashes, activePresses: &activePresses)
    }

    func ensureCache(size: CGSize, displayScale: CGFloat, trackpad: Bool, kind: MacKeyboardKind, isDark: Bool) -> VizCache {
        let ds = max(1, displayScale)
        let pw = max(1, Int((size.width * ds).rounded()))
        let ph = max(1, Int((size.height * ds).rounded()))
        let key = CacheKey(widthPx: pw, heightPx: ph, displayScale: ds, trackpad: trackpad, kind: kind, isDark: isDark)
        if let c = cache, c.key == key {
            return c
        }
        if let idx = Self.sharedCaches.firstIndex(where: { $0.key == key }) {
            let hit = Self.sharedCaches.remove(at: idx)
            Self.sharedCaches.append(hit)
            cache = hit
            return hit
        }
        let built = VizRasterizer.buildCache(key: key, size: size, displayScale: ds, trackpad: trackpad, kind: kind, isDark: isDark)
        Self.sharedCaches.append(built)
        if Self.sharedCaches.count > 4 { Self.sharedCaches.removeFirst() }
        cache = built
        return built
    }
}

// MARK: - Static Rasterizer (runs once per size + appearance, zero per-frame SwiftUI symbols or blur)

@MainActor
private enum VizRasterizer {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .workingColorSpace: sRGB])

    static func buildCache(
        key: KeyboardVizModel.CacheKey,
        size: CGSize,
        displayScale ds: CGFloat,
        trackpad: Bool,
        kind: MacKeyboardKind,
        isDark: Bool
    ) -> KeyboardVizModel.VizCache {
        let lay = VizLayout(size: size, trackpad: trackpad, kind: kind)
        let s = lay.scale
        let caps = KeyLayout.caps(for: kind)
        let keyR = min(5.5, max(2.2, s * 0.115))
        let bleedExpand = max(1.2, s * 0.032)
        let socketExpand = max(0.6, s * 0.015)

        var keyRects = [CGRect](); keyRects.reserveCapacity(caps.count)
        var keyPaths = [Path](); keyPaths.reserveCapacity(caps.count)
        var bleedPaths = [Path](); bleedPaths.reserveCapacity(caps.count)
        var socketPaths = [Path](); socketPaths.reserveCapacity(caps.count)
        var keyBleedKeys = [KeyboardVizModel.BleedSpriteKey](); keyBleedKeys.reserveCapacity(caps.count)
        var indexByCode: [UInt16: Int] = [:]
        var touchOuter: Path?
        var touchInner: Path?

        for (i, cap) in caps.enumerated() {
            let r = lay.rect(cap)
            let cr = min(keyR, r.height * 0.24)
            keyRects.append(r)
            keyPaths.append(Path(roundedRect: r, cornerRadius: cr, style: .continuous))
            bleedPaths.append(Path(roundedRect: r.insetBy(dx: -bleedExpand, dy: -bleedExpand),
                                   cornerRadius: cr + bleedExpand * 0.6, style: .continuous))
            socketPaths.append(Path(roundedRect: r.insetBy(dx: -socketExpand, dy: -socketExpand),
                                    cornerRadius: cr + socketExpand * 0.5, style: .continuous))
            keyBleedKeys.append(KeyboardVizModel.BleedSpriteKey(
                widthHalfPt: Int((r.width * 2).rounded()),
                heightHalfPt: Int((r.height * 2).rounded()),
                radiusHalfPt: Int((cr * 2).rounded())
            ))
            if cap.keyCode != 0xFFFF {
                indexByCode[cap.keyCode] = i
            } else {
                let d = min(r.width, r.height) * 0.60
                let outer = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
                let innerD = d * 0.72
                let inner = CGRect(x: r.midX - innerD / 2, y: r.midY - innerD / 2, width: innerD, height: innerD)
                touchOuter = Path(ellipseIn: outer)
                touchInner = Path(ellipseIn: inner)
            }
        }

        let fullRect = CGRect(origin: .zero, size: size)
        let br = lay.boardRect
        let boardR = max(6, s * 0.36)
        let boardPath = Path(roundedRect: br, cornerRadius: boardR, style: .continuous)
        let boardInnerPath = Path(roundedRect: br.insetBy(dx: 0.75, dy: 0.75), cornerRadius: max(4, boardR - 0.75), style: .continuous)
        let tr = lay.trackpadRect
        let tpR = min(tr.height * 0.14, s * 0.38)
        let trackpadPath = Path(roundedRect: tr, cornerRadius: tpR, style: .continuous)

        let haloBlur = max(1.4, s * 0.048)
        let bleedBlur = max(3.0, s * 0.125)
        let boardClipMargin = ceil(max(2.0, haloBlur * 3.0))
        let boardClipRect = snapRectToPixels(br.insetBy(dx: -boardClipMargin, dy: -boardClipMargin).intersection(fullRect), scale: ds)
        let bleedMargin = ceil(bleedBlur * 3.0 + bleedExpand)
        let boardGlowRect = snapRectToPixels(br.insetBy(dx: -bleedMargin, dy: -bleedMargin).intersection(fullRect), scale: ds)

        // Pre-render crisp legends once (used in staticBaseImage @ 0.28, litOverlayImage @ 1.0, and haloImage)
        var legendsCG: CGImage?
        var haloImage: Image?
        var keyLegendSprites = [KeyboardVizModel.KeySprite?](repeating: nil, count: caps.count)
        var keyHaloSprites = [KeyboardVizModel.KeySprite?](repeating: nil, count: caps.count)

        if s >= 20 {
            let lcg = renderBitmap(rect: boardClipRect, scale: ds) { cg, _ in
                let nsCtx = NSGraphicsContext(cgContext: cg, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsCtx
                for (i, cap) in caps.enumerated() where cap.keyCode != 0xFFFF && !cap.label.isEmpty {
                    drawLegendNS(cap: cap, rect: keyRects[i])
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            legendsCG = lcg

            // Halo is blurred >=1.4pt; 1x scale is visually identical and 4x cheaper to blend per frame
            let haloCGFull = gaussianBlur(lcg, radiusPx: haloBlur * ds)
            let bx = boardClipRect.minX
            let by = boardClipRect.minY
            for (i, cap) in caps.enumerated() where cap.keyCode != 0xFFFF && !cap.label.isEmpty {
                let r = keyRects[i]
                keyLegendSprites[i] = cropSprite(from: lcg, rect: r, boardOrigin: CGPoint(x: bx, y: by), scale: ds)
                keyHaloSprites[i] = cropSprite(from: haloCGFull, rect: r, boardOrigin: CGPoint(x: bx, y: by), scale: ds)
            }
            haloImage = Image(decorative: haloCGFull, scale: ds, orientation: .up)
        }

        // 1. Static base image: deck + sockets + trackpad + unlit keycaps + Touch ID + unlit legends (0.28)
        let staticBaseCG = renderBitmap(rect: fullRect, scale: ds) { cg, _ in
            switch kind {
            case .macBookPro:
                let well = isDark
                    ? CGColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1)
                    : CGColor(srgbRed: 0.067, green: 0.067, blue: 0.078, alpha: 1)
                cg.setFillColor(well)
                cg.addPath(boardPath.cgPath)
                cg.fillPath()

                let outerEdge = isDark
                    ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
                    : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32)
                cg.setStrokeColor(outerEdge)
                cg.setLineWidth(isDark ? 0.7 : 1.0)
                cg.addPath(boardPath.cgPath)
                cg.strokePath()

                cg.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: isDark ? 0.03 : 0.06))
                cg.setLineWidth(0.5)
                cg.addPath(boardInnerPath.cgPath)
                cg.strokePath()
            case .macBookAir, .macBookAirM1:
                let deck = isDark
                    ? CGColor(srgbRed: 0.115, green: 0.122, blue: 0.140, alpha: 1)
                    : CGColor(srgbRed: 0.855, green: 0.862, blue: 0.878, alpha: 1)
                cg.setFillColor(deck)
                cg.addPath(boardPath.cgPath)
                cg.fillPath()

                let edge = isDark
                    ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
                    : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16)
                cg.setStrokeColor(edge)
                cg.setLineWidth(0.75)
                cg.addPath(boardPath.cgPath)
                cg.strokePath()

                if !isDark {
                    cg.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
                    for p in socketPaths { cg.addPath(p.cgPath); cg.fillPath() }
                }
            }

            if trackpad {
                let tpFill: CGColor = {
                    switch (kind, isDark) {
                    case (_, true): return CGColor(srgbRed: 0.086, green: 0.086, blue: 0.098, alpha: 1)
                    case (.macBookPro, false): return CGColor(srgbRed: 0.84, green: 0.845, blue: 0.865, alpha: 1)
                    case (.macBookAir, false), (.macBookAirM1, false): return CGColor(srgbRed: 0.85, green: 0.855, blue: 0.875, alpha: 1)
                    }
                }()
                cg.setFillColor(tpFill)
                cg.addPath(trackpadPath.cgPath)
                cg.fillPath()

                cg.setStrokeColor(isDark
                    ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
                    : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16))
                cg.setLineWidth(0.6)
                cg.addPath(trackpadPath.cgPath)
                cg.strokePath()
            }

            let unlitFill = CGColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1)
            let unlitRim = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
            cg.setLineWidth(0.5)
            for p in keyPaths {
                cg.setFillColor(unlitFill)
                cg.addPath(p.cgPath)
                cg.fillPath()
                cg.setStrokeColor(unlitRim)
                cg.addPath(p.cgPath)
                cg.strokePath()
            }
            if let outer = touchOuter, let inner = touchInner {
                cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
                cg.addPath(outer.cgPath)
                cg.fillPath()
                cg.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
                cg.setLineWidth(0.9)
                cg.addPath(outer.cgPath)
                cg.strokePath()
                cg.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09))
                cg.setLineWidth(0.5)
                cg.addPath(inner.cgPath)
                cg.strokePath()
            }

            if let lcg = legendsCG {
                cg.saveGState()
                cg.setAlpha(0.28)
                drawCGImageTopLeft(lcg, in: boardClipRect, cg: cg)
                cg.restoreGState()
            }
        }

        // 2. Pre-blurred full-board under-key bleed (used inside litOverlayImage)
        let bleedStrength: Double = isDark ? 0.52 : 0.44
        let bleedColor = CGColor(srgbRed: 1.0, green: 0.988, blue: 0.960, alpha: bleedStrength)
        let rawBleedCG = renderBitmap(rect: boardGlowRect, scale: ds) { cg, _ in
            cg.setFillColor(bleedColor)
            for i in 0..<caps.count where caps[i].keyCode != 0xFFFF {
                cg.addPath(bleedPaths[i].cgPath)
                cg.fillPath()
            }
        }
        let blurredBleedCG = gaussianBlur(rawBleedCG, radiusPx: bleedBlur * ds)

        // 2b. Pre-blurred per-size bleed sprites (~7 unique sizes) for individual key flashes
        var bleedSprites: [KeyboardVizModel.BleedSpriteKey: KeyboardVizModel.BleedSprite] = [:]
        let spritePad = ceil(bleedBlur * 3.0 + bleedExpand + 2)
        for bk in Set(keyBleedKeys) {
            let w = CGFloat(bk.widthHalfPt) / 2.0
            let h = CGFloat(bk.heightHalfPt) / 2.0
            let cr = CGFloat(bk.radiusHalfPt) / 2.0
            let box = CGRect(x: 0, y: 0, width: w + 2 * spritePad, height: h + 2 * spritePad)
            let raw = renderBitmap(rect: box, scale: 1.0) { cg, _ in
                let rr = CGRect(x: spritePad - bleedExpand, y: spritePad - bleedExpand,
                                width: w + 2 * bleedExpand, height: h + 2 * bleedExpand)
                let p = Path(roundedRect: rr, cornerRadius: cr + bleedExpand * 0.6, style: .continuous)
                cg.setFillColor(bleedColor)
                cg.addPath(p.cgPath)
                cg.fillPath()
            }
            let blurred = gaussianBlur(raw, radiusPx: bleedBlur)
            bleedSprites[bk] = KeyboardVizModel.BleedSprite(
                image: Image(decorative: blurred, scale: 1.0, orientation: .up),
                pad: spritePad
            )
        }

        // 3. Consolidated lit overlay (bleed clipped to well + opaque lit keycaps + full-bright legends) -> drawn at opacity = L
        let litOverlayCG = renderBitmap(rect: boardClipRect, scale: ds) { cg, _ in
            cg.saveGState()
            cg.addPath(boardPath.cgPath)
            cg.clip()
            drawCGImageTopLeft(blurredBleedCG, in: boardGlowRect, cg: cg)
            cg.restoreGState()
            let litFill = CGColor(srgbRed: 0.118, green: 0.118, blue: 0.132, alpha: 1)
            let litRim = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
            cg.setLineWidth(0.5)
            for i in 0..<caps.count where caps[i].keyCode != 0xFFFF {
                let p = keyPaths[i]
                cg.setFillColor(litFill)
                cg.addPath(p.cgPath)
                cg.fillPath()
                cg.setStrokeColor(litRim)
                cg.addPath(p.cgPath)
                cg.strokePath()
            }
            if let lcg = legendsCG {
                drawCGImageTopLeft(lcg, in: boardClipRect, cg: cg)
            }
        }

        return KeyboardVizModel.VizCache(
            key: key, size: size, trackpad: trackpad, kind: kind, isDark: isDark,
            scale: s, origin: lay.origin, fullRect: fullRect, boardRect: br,
            boardClipRect: boardClipRect, boardPath: boardPath,
            trackpadRect: tr, trackpadPath: trackpadPath,
            caps: caps, keyRects: keyRects, keyPaths: keyPaths, keyRadius: keyR,
            touchIDOuterPath: touchOuter, touchIDInnerPath: touchInner, indexByCode: indexByCode,
            staticBaseImage: Image(decorative: staticBaseCG, scale: ds, orientation: .up),
            litOverlayImage: Image(decorative: litOverlayCG, scale: ds, orientation: .up),
            haloImage: haloImage,
            bleedStrength: bleedStrength,
            bleedSprites: bleedSprites,
            keyBleedKeys: keyBleedKeys,
            keyLegendSprites: keyLegendSprites,
            keyHaloSprites: keyHaloSprites
        )
    }

    private static func drawCGImageTopLeft(_ img: CGImage, in rect: CGRect, cg: CGContext) {
        // `cg` has Y-flipped (top-left) CTM; CGContext.draw(_:in:) flips the image internally,
        // so temporarily flip locally around `rect` to draw right-side up.
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    private static func snapRectToPixels(_ r: CGRect, scale: CGFloat) -> CGRect {
        let minX = floor(r.minX * scale) / scale
        let minY = floor(r.minY * scale) / scale
        let maxX = ceil(r.maxX * scale) / scale
        let maxY = ceil(r.maxY * scale) / scale
        return CGRect(x: minX, y: minY, width: max(1 / scale, maxX - minX), height: max(1 / scale, maxY - minY))
    }

    private static func renderBitmap(rect: CGRect, scale: CGFloat, draw: (CGContext, CGSize) -> Void) -> CGImage {
        let pw = max(1, Int((rect.width * scale).rounded()))
        let ph = max(1, Int((rect.height * scale).rounded()))
        guard let cg = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to create bitmap CGContext")
        }
        cg.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        cg.translateBy(x: 0, y: CGFloat(ph))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        draw(cg, rect.size)
        return cg.makeImage()!
    }

    private static func gaussianBlur(_ src: CGImage, radiusPx: CGFloat) -> CGImage {
        let ci = CIImage(cgImage: src)
        let extent = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return src }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(radiusPx, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage,
              let cg = ciContext.createCGImage(out, from: extent, format: .RGBA8, colorSpace: sRGB) else {
            return src
        }
        return cg
    }

    private static func cropSprite(from src: CGImage, rect: CGRect, boardOrigin: CGPoint, scale: CGFloat) -> KeyboardVizModel.KeySprite? {
        let pxRect = CGRect(
            x: (rect.minX - boardOrigin.x) * scale,
            y: (rect.minY - boardOrigin.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard !pxRect.isEmpty, let sub = src.cropping(to: pxRect) else { return nil }
        let drawRect = CGRect(
            x: boardOrigin.x + pxRect.minX / scale,
            y: boardOrigin.y + pxRect.minY / scale,
            width: pxRect.width / scale,
            height: pxRect.height / scale
        )
        return KeyboardVizModel.KeySprite(
            image: Image(decorative: sub, scale: scale, orientation: .up),
            drawRect: drawRect
        )
    }

    // Legend glyphs rendered once into `legendsImage` using AppKit (matches SwiftUI Text + SF Symbols)
    private enum LegendAnchor { case center, bottomLeading, bottomTrailing, bottom, topLeading, topTrailing }

    private static let cachedArrowSprites: [UInt16: NSImage] = {
        let map: [(UInt16, String)] = [
            (123, "arrowtriangle.left.fill"),
            (124, "arrowtriangle.right.fill"),
            (125, "arrowtriangle.down.fill"),
            (126, "arrowtriangle.up.fill"),
        ]
        let cfg = NSImage.SymbolConfiguration(pointSize: 5.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        var d: [UInt16: NSImage] = [:]
        for (code, name) in map {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                d[code] = img
            }
        }
        return d
    }()

    private static let cachedGlobeSprite: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }()

    private static func drawLegendNS(cap: KeyCap, rect r: CGRect) {
        let minH: CGFloat = cap.kind == .arrow ? 8 : 16
        guard r.height >= minH else { return }
        let padX: CGFloat = 5
        let padY: CGFloat = 4

        func drawSymbol(_ img: NSImage?, at pt: CGPoint, anchor: LegendAnchor) {
            guard let img else { return }
            let sz = img.size
            let origin = alignedOrigin(size: sz, at: pt, anchor: anchor)
            img.draw(in: CGRect(origin: origin, size: sz), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }

        func drawText(_ text: String, size fs: CGFloat, weight w: NSFont.Weight, at pt: CGPoint, anchor: LegendAnchor) {
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: w),
                .foregroundColor: NSColor.white,
            ])
            let sz = attr.size()
            let origin = alignedOrigin(size: sz, at: pt, anchor: anchor)
            attr.draw(at: origin)
        }

        func drawMain(at pt: CGPoint, anchor: LegendAnchor) {
            if let arrow = cachedArrowSprites[cap.keyCode] {
                drawSymbol(arrow, at: pt, anchor: anchor)
                return
            }
            let fs: CGFloat = {
                if cap.kind == .function { return 7.5 }
                if cap.label.count > 1 { return 7.2 }
                return 10.0
            }()
            let w: NSFont.Weight = cap.label.count == 1 ? .regular : .medium
            drawText(cap.label, size: fs, weight: w, at: pt, anchor: anchor)
        }

        switch cap.keyCode {
        case 63: // fn + globe
            drawSymbol(cachedGlobeSprite, at: CGPoint(x: r.minX + padX, y: r.maxY - padY), anchor: .bottomLeading)
            drawMain(at: CGPoint(x: r.maxX - padX, y: r.minY + padY), anchor: .topTrailing)
        case 59: // left control
            drawText("⌃", size: 8, weight: .medium, at: CGPoint(x: r.maxX - padX, y: r.minY + padY), anchor: .topTrailing)
            drawMain(at: CGPoint(x: r.midX, y: r.maxY - padY), anchor: .bottom)
        case 58: // left option
            drawText("⌥", size: 8, weight: .medium, at: CGPoint(x: r.maxX - padX, y: r.minY + padY), anchor: .topTrailing)
            drawMain(at: CGPoint(x: r.midX, y: r.maxY - padY), anchor: .bottom)
        case 55: // left command
            drawText("⌘", size: 8.5, weight: .medium, at: CGPoint(x: r.maxX - padX, y: r.minY + padY), anchor: .topTrailing)
            drawMain(at: CGPoint(x: r.midX, y: r.maxY - padY), anchor: .bottom)
        case 54: // right command
            drawText("⌘", size: 8.5, weight: .medium, at: CGPoint(x: r.minX + padX, y: r.minY + padY), anchor: .topLeading)
            drawMain(at: CGPoint(x: r.midX, y: r.maxY - padY), anchor: .bottom)
        case 61: // right option
            drawText("⌥", size: 8, weight: .medium, at: CGPoint(x: r.minX + padX, y: r.minY + padY), anchor: .topLeading)
            drawMain(at: CGPoint(x: r.midX, y: r.maxY - padY), anchor: .bottom)
        case 53, 48, 57, 56: // esc, tab, caps, left shift
            drawMain(at: CGPoint(x: r.minX + padX, y: r.maxY - padY), anchor: .bottomLeading)
        case 51, 36, 60: // delete, return, right shift
            drawMain(at: CGPoint(x: r.maxX - padX, y: r.maxY - padY), anchor: .bottomTrailing)
        default:
            drawMain(at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
        }
    }

    private static func alignedOrigin(size sz: CGSize, at pt: CGPoint, anchor: LegendAnchor) -> CGPoint {
        switch anchor {
        case .center:         return CGPoint(x: pt.x - sz.width / 2, y: pt.y - sz.height / 2)
        case .bottomLeading:  return CGPoint(x: pt.x, y: pt.y - sz.height)
        case .bottomTrailing: return CGPoint(x: pt.x - sz.width, y: pt.y - sz.height)
        case .bottom:         return CGPoint(x: pt.x - sz.width / 2, y: pt.y - sz.height)
        case .topLeading:     return CGPoint(x: pt.x, y: pt.y)
        case .topTrailing:    return CGPoint(x: pt.x - sz.width, y: pt.y)
        }
    }
}

// MARK: - Trackpad ring drawing (shared with TrackpadGlyph)

enum TrackpadDraw {
    static func draw(_ ctx: inout GraphicsContext, rect: CGRect, scale: CGFloat, now: Double, reduceMotion: Bool,
                     shape: Path? = nil, kind: MacKeyboardKind = KeyLayout.kind, isDark: Bool = true) {
        let radius = min(rect.height * 0.14, scale * 0.38)
        let tpShape = shape ?? Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        let fill: Color = {
            switch (kind, isDark) {
            case (_, true): return Color(red: 0.086, green: 0.086, blue: 0.098)
            case (.macBookPro, false): return Color(red: 0.84, green: 0.845, blue: 0.865)
            case (.macBookAir, false), (.macBookAirM1, false): return Color(red: 0.85, green: 0.855, blue: 0.875)
            }
        }()
        ctx.fill(tpShape, with: .color(fill))
        drawOverlay(&ctx, rect: rect, scale: scale, now: now, reduceMotion: reduceMotion,
                    radius: radius, shape: tpShape, isDark: isDark)
        ctx.stroke(tpShape, with: .color(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.16)), lineWidth: 0.6)
    }

    /// Draws only the dynamic haptic pulse/ring (when the static trackpad base & border are already cached).
    static func drawOverlay(_ ctx: inout GraphicsContext, rect: CGRect, scale: CGFloat, now: Double, reduceMotion: Bool,
                            radius: CGFloat? = nil, shape: Path? = nil, isDark: Bool = true) {
        let hit = HapticBus.shared.lastHit()
        let t = now - hit.time
        guard hit.time > 0, t >= 0, t < 0.6 else { return }
        let r = radius ?? min(rect.height * 0.14, scale * 0.38)
        let tpShape = shape ?? Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        let lvl = CGFloat(max(0.25, min(1, hit.level)))
        let p = CGFloat(t / 0.6)
        let fade = (1 - p) * (1 - p)
        ctx.fill(tpShape, with: .color(Theme.glow.opacity(Double(fade * lvl) * 0.22)))
        let grow = reduceMotion ? 0 : p * scale * 0.55
        let ring = Path(roundedRect: rect.insetBy(dx: -grow, dy: -grow), cornerRadius: r + grow, style: .continuous)
        ctx.stroke(ring, with: .color(Theme.glow.opacity(Double(fade * lvl) * 0.9)), lineWidth: 1.2)
    }
}

@MainActor
@Observable
private final class TrackpadGlyphModel {
    private(set) var isAnimating = true
    private(set) var saver = PowerState.shared.saver
    @ObservationIgnored private var viewVisible = true
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var timerMs = 50
    @ObservationIgnored private var lastHitT: Double = 0
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    init() {
        powerObserver = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSaver() }
        }
    }

    private func refreshSaver() {
        let s = PowerState.shared.saver
        if s != saver { saver = s }
        if timer != nil { sync() }
    }

    func start() { viewVisible = true; refreshSaver(); sync() }
    func stop() { viewVisible = false; sync() }
    func setWindowVisible(_ v: Bool) { windowVisible = v; sync() }

    private func sync() {
        guard viewVisible && windowVisible else {
            timer?.cancel(); timer = nil
            if isAnimating { isAnimating = false }
            return
        }
        let ms = saver ? 100 : 50
        if let t = timer {
            if ms != timerMs {
                timerMs = ms
                t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(ms / 4))
            }
            return
        }
        timerMs = ms
        let t = DispatchSource.makeTimerSource(flags: [], queue: .main)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(ms / 4))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
        poll()
    }

    private func poll() {
        let now = hostNow()
        let hitT = HapticBus.shared.lastHit().time
        if hitT != lastHitT { lastHitT = hitT }
        let active = hitT > 0 && now - hitT < 0.65
        if active != isAnimating { isAnimating = active }
    }

    deinit {
        if let o = powerObserver { NotificationCenter.default.removeObserver(o) }
        timer?.cancel()
    }
}

/// Small standalone trackpad glyph that rings on every haptic actuation.
struct TrackpadGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = TrackpadGlyphModel()

    var body: some View {
        TimelineView(.animation(minimumInterval: model.saver ? 1.0 / 30 : 1.0 / 60, paused: !model.isAnimating)) { tl in
            Canvas { ctx, size in
                let _ = tl.date
                let w = min(size.width - 24, (size.height - 24) * 1.7)
                let rect = CGRect(x: (size.width - w) / 2, y: (size.height - w / 1.7) / 2, width: w, height: w / 1.7)
                TrackpadDraw.draw(&ctx, rect: rect, scale: w / 5.6, now: hostNow(), reduceMotion: reduceMotion,
                                  isDark: colorScheme == .dark)
            }
        }
        .background(WindowVisibilityProbe { model.setWindowVisible($0) })
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .accessibilityHidden(true)
    }
}

// MARK: - View

struct KeyboardVisualizer: View {
    enum Style { case glow, sounds }

    var style: Style = .glow
    var showTrackpad: Bool = false
    var interactive: Bool = false
    var kind: MacKeyboardKind = KeyLayout.kind
    var previewLevel: Float? = nil
    var onKey: ((KeyCap) -> Void)? = nil
    /// Externally typed key (e.g. from KeyCatcher): lights that key like a click would. `seq` makes repeats distinct.
    var trigger: KeyTrigger? = nil

    struct KeyTrigger: Equatable { var keyCode: UInt16; var seq: Int }

    @State private var model = KeyboardVizModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: model.saver ? 1.0 / 30 : 1.0 / 60, paused: !model.isAnimating)) { tl in
                Canvas(rendersAsynchronously: false) { ctx, size in
                    let _ = tl.date
                    draw(&ctx, size, ctx.environment)
                }
            }
            .background(WindowVisibilityProbe { model.setWindowVisible($0) })
            .contentShape(Rectangle())
            .onTapGesture(count: 1, coordinateSpace: .local) { p in
                guard interactive else { return }
                let lay = VizLayout(size: geo.size, trackpad: showTrackpad, kind: kind)
                if let cap = lay.cap(at: p) {
                    model.triggerKey(cap.keyCode, now: hostNow())
                    onKey?(cap)
                }
            }
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .active(let p):
                    let id = VizLayout(size: geo.size, trackpad: showTrackpad, kind: kind).cap(at: p)?.id
                    if id != model.hoverID { model.hoverID = id; model.wake() }
                case .ended:
                    if model.hoverID != nil { model.hoverID = nil; model.wake() }
                }
            }
        }
        .aspectRatio(VizLayout.aspect(trackpad: showTrackpad, kind: kind), contentMode: .fit)
        .onAppear {
            model.configure(style: style, showTrackpad: showTrackpad, previewLevel: previewLevel)
            model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: trigger) { _, t in
            guard let t else { return }
            model.triggerKey(t.keyCode, now: hostNow())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .macBookPro ? "MacBook Pro keyboard live view" : "MacBook Air keyboard live view")
    }

    // Frame ----------------------------------------------------------------------------------

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ env: EnvironmentValues) {
        let now = hostNow()
        let m = model
        m.configure(style: style, showTrackpad: showTrackpad, previewLevel: previewLevel)
        let isDark = env.colorScheme == .dark
        // Build the cache on a 16 pt grid and scale it to the live size, so a window resize
        // rebuilds at most once per step instead of every frame.
        let step: CGFloat = 16
        let qsize = CGSize(width: max(step, (size.width / step).rounded(.up) * step),
                           height: max(step, (size.height / step).rounded(.up) * step))
        let c = m.ensureCache(size: qsize, displayScale: env.displayScale, trackpad: showTrackpad, kind: kind, isDark: isDark)
        if qsize != size, size.width > 0, size.height > 0 {
            ctx.scaleBy(x: size.width / qsize.width, y: size.height / qsize.height)
        }
        let s = c.scale

        // Perceived backlight brightness (sqrt of hardware drive level, matching GlowEngine.drivePower = 2)
        let rawTarget: Float = previewLevel ?? (style == .glow ? GlowEngine.shared.currentLevel : 0)
        let target: Float = rawTarget <= 0 ? 0 : sqrtf(min(1, max(0, rawTarget)))
        if m.lastT == 0 {
            m.level = target
        } else {
            let dt = min(0.1, max(0, now - m.lastT))
            m.level += (target - m.level) * Float(1 - exp(-dt / 0.015))
        }
        m.lastT = now
        let L = max(0, min(1, m.level))
        m.snapshot(now: now)

        // Per-key brightness = global perceived level + short KeyBus press/flash boost
        let n = c.caps.count
        if m.lit.count != n {
            m.lit = [Float](repeating: L, count: n)
            m.pressAmounts = [Float](repeating: 0, count: n)
        } else {
            for i in 0..<n {
                m.lit[i] = c.caps[i].keyCode == 0xFFFF ? 0 : L
                m.pressAmounts[i] = 0
            }
        }
        if L > 0, let touchIdx = c.caps.firstIndex(where: { $0.keyCode == 0xFFFF }) {
            m.lit[touchIdx] = 0
        }

        var hasPerKeyBoost = false
        for fl in m.activeFlashes {
            guard let idx = c.indexByCode[fl.keyCode] else { continue }
            let age = max(0, now - fl.t0)
            let v = fl.amp * Float(exp(-age / 0.085))
            if v > 0.01 {
                let boosted = min(1, m.lit[idx] + v * (1 - m.lit[idx] * 0.35))
                if boosted > m.lit[idx] {
                    m.lit[idx] = boosted
                    if boosted > L + 0.01 { hasPerKeyBoost = true }
                }
            }
        }
        var hasPress = false
        for p in m.activePresses {
            guard let idx = c.indexByCode[p.code] else { continue }
            let amt = p.up < 0 ? Float(min(1, (now - p.down) / 0.035)) : Float(max(0, 1 - (now - p.up) / 0.16))
            if amt > 0.01 {
                m.pressAmounts[idx] = amt
                hasPress = true
                if p.up < 0 {
                    let holdGlow = min(1, max(m.lit[idx], 0.72 * amt + L * 0.28))
                    if holdGlow > m.lit[idx] {
                        m.lit[idx] = holdGlow
                        if holdGlow > L + 0.01 { hasPerKeyBoost = true }
                    }
                }
            }
        }

        // 1. Static base (deck + well + sockets + trackpad + unlit keycaps + unlit legends)
        ctx.draw(c.staticBaseImage, in: c.fullRect)

        // 2. Global lit overlay (bleed + lit keycaps + bright legends), composited by opacity = L
        if L > 0.01 {
            ctx.opacity = Double(L)
            ctx.draw(c.litOverlayImage, in: c.boardClipRect)
            ctx.opacity = 1
        }

        // 3. Global legend halo (pre-blurred image, composited with plusLighter)
        if let haloImage = c.haloImage, L > 0.08 {
            ctx.blendMode = .plusLighter
            ctx.opacity = Double((L - 0.08) / 0.92) * 0.60
            ctx.draw(haloImage, in: c.boardClipRect)
            ctx.blendMode = .normal
            ctx.opacity = 1
        }

        // 4. Per-key dynamic overrides only for the 0..3 keys currently pressed, flashed above L, or hovered
        if hasPress || hasPerKeyBoost || m.hoverID != nil {
            let keyUnlit = Color(red: 0.094, green: 0.094, blue: 0.106)
            let keyPressed = Color(red: 0.072, green: 0.072, blue: 0.082)
            let wellCover: Color = {
                switch kind {
                case .macBookPro:
                    return isDark ? Color(red: 0.043, green: 0.043, blue: 0.051) : Color(red: 0.067, green: 0.067, blue: 0.078)
                case .macBookAir, .macBookAirM1:
                    if !isDark { return Color(red: 0.12, green: 0.12, blue: 0.14) }
                    return Color(red: 0.115, green: 0.122, blue: 0.140)
                }
            }()

            if hasPerKeyBoost {
                var bleedCtx = ctx
                bleedCtx.clip(to: c.boardPath)
                let baseAlpha = Double(L) * c.bleedStrength
                for i in 0..<n {
                    let t = m.lit[i]
                    guard t > L + 0.01, c.caps[i].keyCode != 0xFFFF else { continue }
                    guard let sprite = c.bleedSprites[c.keyBleedKeys[i]] else { continue }
                    let targetAlpha = Double(t) * c.bleedStrength
                    let extra = max(0, min(1, (targetAlpha - baseAlpha) / max(0.01, 1 - baseAlpha)))
                    guard extra > 0.005 else { continue }
                    let r = c.keyRects[i].insetBy(dx: -sprite.pad, dy: -sprite.pad)
                    bleedCtx.opacity = extra
                    bleedCtx.draw(sprite.image, in: r)
                }
            }

            for i in 0..<n {
                let cap = c.caps[i]
                let pressAmt = m.pressAmounts[i]
                let t = m.lit[i]
                let isHover = (m.hoverID == cap.id)
                guard pressAmt > 0 || t > L + 0.01 || isHover else { continue }

                var shape = c.keyPaths[i]
                if pressAmt > 0 {
                    ctx.fill(c.keyPaths[i], with: .color(wellCover))
                    let pr = c.keyRects[i].insetBy(dx: 0.45 * CGFloat(pressAmt), dy: 0.45 * CGFloat(pressAmt))
                        .offsetBy(dx: 0, dy: 0.55 * CGFloat(pressAmt))
                    shape = Path(roundedRect: pr, cornerRadius: min(c.keyRadius, pr.height * 0.24), style: .continuous)
                }

                let fill: Color
                if pressAmt > 0.15 {
                    fill = keyPressed
                } else if t > 0.01 {
                    let k = Double(t)
                    fill = Color(red: 0.094 + 0.024 * k, green: 0.094 + 0.024 * k, blue: 0.106 + 0.026 * k)
                } else {
                    fill = keyUnlit
                }
                ctx.fill(shape, with: .color(fill))

                if isHover {
                    ctx.stroke(shape, with: .color(Theme.accent), lineWidth: 1.0)
                } else {
                    let rimAlpha = 0.08 + 0.10 * Double(t)
                    ctx.stroke(shape, with: .color(Color.white.opacity(rimAlpha)), lineWidth: 0.5)
                }

                if cap.keyCode == 0xFFFF {
                    if let outer = c.touchIDOuterPath, let inner = c.touchIDInnerPath {
                        ctx.fill(outer, with: .color(Color.black.opacity(0.35)))
                        ctx.stroke(outer, with: .color(Color.white.opacity(0.18)), lineWidth: 0.9)
                        ctx.stroke(inner, with: .color(Color.white.opacity(0.09)), lineWidth: 0.5)
                    }
                    continue
                }

                if t > 0.08, let hSprite = c.keyHaloSprites[i] {
                    ctx.blendMode = .plusLighter
                    ctx.opacity = Double((t - 0.08) / 0.92) * 0.60
                    ctx.draw(hSprite.image, in: hSprite.drawRect)
                    ctx.blendMode = .normal
                }
                if let lSprite = c.keyLegendSprites[i] {
                    ctx.opacity = 0.28 + 0.72 * Double(t)
                    ctx.draw(lSprite.image, in: lSprite.drawRect)
                }
                ctx.opacity = 1
            }
        }

        // 5. Dynamic trackpad haptic ring (static trackpad is already in staticBaseImage)
        if c.trackpad {
            TrackpadDraw.drawOverlay(&ctx, rect: c.trackpadRect, scale: s, now: now, reduceMotion: reduceMotion,
                                     shape: c.trackpadPath, isDark: isDark)
        }
    }
}
