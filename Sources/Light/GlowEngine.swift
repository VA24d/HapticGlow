// HapticGlow — keyboard glow renderer (240 Hz music / 60 Hz ambient) with every GlowMode.
//
// All shapes are computed in PERCEIVED brightness (0...1, roughly lightness) and mapped to the
// hardware drive level with one power curve (`GlowEngine.drivePower`), so fades look even to the eye
// instead of bunching at the bright end. Attacks are ~10 ms ease-outs, releases normalised
// exponentials; the final smoother only slows falls, never rises. No quantisation happens here.
//
// Music-driven modes are time-shifted by SyncClock.delay so the light lands when the listener hears
// the beat (capture sees audio before the output device plays it). Onsets are scheduled at
// lastOnsetTime + delay (lookahead); continuous modes read FeatureBus.delayed(). Key-driven modes and
// the key-flash overlay are local and never delayed.
//
// Envelope ideas follow MagicKey (MIT, XiaoSong1223).
import Foundation

// MARK: - Pure shape helpers (shared by the renderer and the UI previews)

enum GlowShape {
    @inline(__always) static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
    @inline(__always) static func ss(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    @inline(__always) static func ssf(_ x: Float) -> Float { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    /// Ease-out attack (quarter sine) over `att`, then normalised exponential release over `dur`
    /// that lands exactly on 0 at the end. Peak 1 at age == att.
    static func env(_ age: Double, att: Double, dur: Double, k: Float = 2.6) -> Float {
        if age < 0 { return 0 }
        if age < att { return Float(sin(age / att * .pi / 2)) }
        let u = (age - att) / max(dur, 1e-4)
        if u >= 1 { return 0 }
        return release(Float(u), k)
    }
    @inline(__always) static func release(_ u: Float, _ k: Float) -> Float {
        let e = expf(-k)
        return (expf(-k * u) - e) / (1 - e)
    }

    static func hash(_ i: Int) -> Float {
        var x = UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15
        x ^= x >> 31; x = x &* 0xBF58476D1CE4E5B9; x ^= x >> 29
        return Float(x & 0xFFFFFF) / Float(0x7FFFFF) - 1   // -1...1
    }
    static func noise(_ x: Double) -> Float {
        let i = Int(floor(x)); let f = Float(x - floor(x))
        let a = hash(i), b = hash(i + 1)
        return a + (b - a) * ssf(f)
    }
    @inline(__always) static func u01(_ i: Int) -> Double { Double((hash(i) + 1) / 2) }

    // Ambient modes: pure functions of (phase-integrated) time tt, output in perceived brightness.
    /// Breathe: one 7.5 s cycle, asymmetric like a real breath (inhale ~40%, exhale ~48%, soft holds at the
    /// bottom and top), C1-continuous. It is built in hardware light (PWM duty, ticks of 336) because the
    /// backlight cannot be addressed below duty 54 except by its own linear ramp (~107 ticks/s, see
    /// BacklightDriver): the dark band is crossed by exactly that ramp and the bottom is the true-off
    /// duty 6, so the curve and the hardware agree and there is no step anywhere. Output is perceived
    /// brightness sqrt(duty / 336), which the engine squares back to light.
    static let breatheCycle = 7.5
    static func breatheDuty(_ s: Double) -> Double {
        let off = 6.0, floorD = 54.0, peak = 336.0, ramp = 48.0 / 0.45     // ticks/s of the hardware ramp
        let hold0 = 0.20, up = 0.45, inhale = 2.60, top = 0.35, exhale = 3.10, down = 0.45   // + 0.35 s hold at the end
        func herm(_ u: Double, _ p0: Double, _ m0: Double, _ p1: Double, _ m1: Double, _ len: Double) -> Double {
            let u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 * len + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1 * len
        }
        var t = s - floor(s / breatheCycle) * breatheCycle
        if t < hold0 { return off }; t -= hold0
        if t < up { return off + (floorD - off) * (t / up) }; t -= up
        if t < inhale { return herm(t / inhale, floorD, ramp, peak, 0, inhale) }; t -= inhale
        if t < top { return peak }; t -= top
        if t < exhale { return herm(t / exhale, peak, 0, floorD, -ramp, exhale) }; t -= exhale
        if t < down { return floorD - (floorD - off) * (t / down) }
        return off
    }
    static func breathe(_ tt: Double) -> Float { Float((breatheDuty(tt) / 336).squareRoot()) }
    static func aurora(_ tt: Double) -> Float {
        clamp01(Float(0.52 + 0.30 * sin(2 * .pi * 0.07 * tt) + 0.14 * sin(2 * .pi * 0.19 * tt + 1.7)
                      + 0.06 * sin(2 * .pi * 0.43 * tt + 0.4)))
    }
    static let heartPeriod = 1.1
    static func heartbeat(_ tt: Double) -> Float {
        let ph = tt - floor(tt / heartPeriod) * heartPeriod
        let lub = env(ph, att: 0.09, dur: 0.26, k: 2.4)
        let dub = 0.7 * env(ph - 0.30, att: 0.09, dur: 0.28, k: 2.4)
        return max(0.10, max(lub, dub))
    }
    static func candle(_ tt: Double) -> Float {
        var l = 0.62 + 0.20 * noise(tt * 7) + 0.10 * noise(tt * 19 + 11) + 0.04 * noise(tt * 43 + 23)
        let slot = Int(floor(tt / 6.5))
        let a = tt - (Double(slot) * 6.5 + 1 + 4 * u01(slot &* 7 + 3))
        if a >= 0 && a < 0.12 { l -= 0.28 * sin(Float(a / 0.12) * .pi) }   // gust dip
        return clamp01(l)
    }
    /// Storm: slowly drifting dim cloud glow plus strikes. 5 s slots, 80% hold a strike: 1–4 sharp
    /// pulses 60–150 ms apart, followed by a soft afterglow that lights the cloud.
    static func lightning(_ tt: Double) -> Float {
        let cloud: Float = 0.26 + 0.07 * noise(tt * 0.5) + 0.03 * noise(tt * 1.7 + 5)
        var glow: Float = 0, pulse: Float = 0
        let k0 = Int(floor(tt / 5))
        for k in (k0 - 1)...k0 {
            if hash(k &* 13 + 1) < -0.6 { continue }
            let start = Double(k) * 5 + 0.3 + 3.9 * u01(k &* 13 + 2)
            let n = 1 + Int(u01(k &* 13 + 3) * 3.99)
            let gap = 0.06 + 0.09 * u01(k &* 13 + 4)
            let age0 = tt - start
            if age0 > 0 { glow = max(glow, 0.55 * Float(min(age0 / 0.03, 1)) * expf(Float(-age0 / 0.45))) }
            for i in 0..<n {
                let age = tt - (start + Double(i) * gap)
                if age < 0 || age > 0.35 { continue }
                let pk: Float = i == 0 ? 1 : 0.55 + 0.45 * Float(u01(k &* 13 + 5 + i))
                pulse = max(pulse, pk * env(age, att: 0.004, dur: 0.14, k: 3.2))
            }
        }
        return clamp01(max(cloud + 0.5 * glow, pulse))
    }
    static func ambient(_ mode: GlowMode, _ tt: Double, steady: Float) -> Float {
        switch mode {
        case .steady: return steady
        case .breathe: return breathe(tt)
        case .heartbeat: return heartbeat(tt)
        case .candle: return candle(tt)
        case .aurora: return aurora(tt)
        case .lightning: return lightning(tt)
        default: return 0
        }
    }
    /// Quiet fallback breathe, 8 s per cycle, kept above the dark band (duty >= 54) so it never needs the glide.
    static func idleBreathe(_ t: Double) -> Float { 0.51 + 0.10 * Float(sin(2 * .pi * t / 8)) }
    /// Sleep breath: slow, slowing with progress `u` (0 ... 1); `phase` is integrated by the caller.
    static func sleepBreath(_ phase: Double) -> Float { 0.25 + 0.75 * Float(0.5 - 0.5 * cos(phase)) }
}

/// One re-triggerable flare: ease-out attack from the current value, then exponential release.
struct GlowFlare {
    var t0 = -1e9
    var base: Float = 0, peak: Float = 0
    var att = 0.010, dur = 0.3
    var k: Float = 2.6

    func value(_ now: Double) -> Float {
        let age = now - t0
        if age < 0 { return base }
        if age < att { return base + (peak - base) * Float(sin(age / att * .pi / 2)) }
        let u = (age - att) / max(dur, 1e-4)
        if u >= 1 { return 0 }
        return peak * GlowShape.release(Float(u), k)
    }
    /// `at` is when the attack begins (<= now). The peak therefore lands at `at + att`.
    mutating func fire(now: Double, at: Double, peak p: Float, att a: Double, dur d: Double, k kk: Float = 2.6) {
        base = value(now)
        att = a; dur = d; k = kk; peak = p
        t0 = min(at, now)
    }
}

// MARK: - Engine

struct KeyState {
    var count: UInt64 = 0
    var lastPress: Double = 0
    var down: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

/// A low-band onset as seen by the analyzer (capture time, not yet delayed).
struct GlowOnset: Sendable { var time: Double; var strength: Float }

/// What the renderer needs from the backlight (BacklightDriver in the app, a recorder in tests).
protocol GlowOutput: AnyObject {
    var isTakenOver: Bool { get }
    var savedBrightness: Float { get }
    func takeOver(keepAwake: Bool)
    func restore()
    func setKeepAwake(_ on: Bool)
    func write(_ level: Float)
    /// Level as a fraction of maximum light (PWM duty), covering the dark band below the lit floor.
    func writeLight(_ light: Float)
}
extension GlowOutput {
    var isTakenOver: Bool { true }
    func writeLight(_ light: Float) { write(BacklightDriver.valueFor(light)) }
}
extension BacklightDriver: GlowOutput {}

/// GlowOutput that records the frame instead of touching hardware (Logitech path).
final class LogiCapture: GlowOutput {
    var light: Float = 0, wrote = false, released = false
    var savedBrightness: Float { 0.3 }
    func takeOver(keepAwake: Bool) {}
    func restore() { released = true }
    func setKeepAwake(_ on: Bool) {}
    func write(_ level: Float) { writeLight(BacklightDriver.lightFor(level)) }
    /// The built-in panel's true off sits at duty 6 / 336; an external keyboard has no such offset, so the
    /// light is re-based to start at 0 (continuous, 1.8% scale change) and the breathe bottom reads as off.
    func writeLight(_ light: Float) {
        let o = BacklightDriver.offLight
        self.light = max(0, (light - o) / (1 - o)); wrote = true
    }
}

private struct OnsetQueue {
    var items: [GlowOnset] = { var a = [GlowOnset](); a.reserveCapacity(64); return a }()
    var lastCount: UInt64 = .max
}

private let musicModes: Set<GlowMode> = [.beatPulse, .bassFollow, .beatStrobe, .metronome, .spectrum]

final class GlowEngine: @unchecked Sendable {
    static let shared = GlowEngine()

    /// Perceived-brightness -> light exponent: light = perceived ^ drivePower, where light is the fraction of
    /// maximum output (PWM duty / 336, linear in light). ~2 matches lightness perception.
    nonisolated(unsafe) static var drivePower: Float = 2.0
    @inline(__always) static func toDrive(_ p: Float) -> Float { p <= 0 ? 0 : powf(min(p, 1), drivePower) }
    @inline(__always) static func toPerceived(_ d: Float) -> Float { d <= 0 ? 0 : powf(min(d, 1), 1 / drivePower) }

    private let cfg = Locked(GlowConfig())
    private let statusBox = Locked<EngineStatus>(.stopped)
    private let levelBox = Locked<Float>(0)
    private let fpsBox = Locked<Double>(0)
    private let musicBox = Locked<Bool>(false)
    private let modeBox = Locked<GlowMode>(.off)
    private let keys = Locked(KeyState())
    private let flashReq = Locked<Int>(0)
    private let queue = DispatchQueue(label: "hapticglow.glow", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let slowFlag = Locked<Bool>(false)   // true while the timer runs at the idle rate
    private var idleSince: Double = 0
    private var lastOutSeen: Float = -2
    private var lastKeyCountSeen: UInt64 = 0
    private var lastPollAt: Double = 0
    private var heartSampling = false
    private var onsetDemand = true
    private static let onsetModes: Set<GlowMode> = [.beatPulse, .beatStrobe, .metronome]
    private static let idleHz = 30
    /// Back to active rate immediately (input arrived while idle). Any thread.
    private func wakeIfSlow() {
        guard slowFlag.get() else { return }
        slowFlag.set(false)
        queue.async { [self] in
            let saver = PowerState.shared.saver
            let want = min(GlowEngine.renderHz(cfg.get(), mixIdle: r.mixIdle,
                                               flash: r.flashLeft > 0 || hostNow() < r.flashUntil),
                           saver ? 60 : 240)
            guard (timerHz < want || saver != timerSaver), let t = timer else { return }
            timerHz = want; timerSaver = saver; idleSince = 0
            t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / timerHz),
                       leeway: .microseconds(saver ? 1000 : 100))
        }
    }
    private var timerHz = 240              // touched on `queue` (and set in start() before the timer runs)
    private var timerSaver = false
    private var keyToken: Int?
    private var featToken: Int?
    private let onsetQ = Locked(OnsetQueue())
    private var r = Renderer()                 // touched only on `queue`
    /// Second renderer for a Logitech keyboard: same modes, drawn `LogitechBacklight.leadSeconds` earlier
    /// so the Bluetooth write lands with the music. Touched only on `queue`.
    private var rLogi = Renderer()
    private let logiOut = LogiCapture()
    private var logiOn = false
    private var logiEverOn = false   // Logitech was engaged at some point this session; stop() hands it back
    private let ctl = UnfairLock()
    private var started = false

    var status: EngineStatus { statusBox.get() }
    var currentLevel: Float { levelBox.get() }
    var fps: Double { fpsBox.get() }
    /// True while the music detector considers music to be playing (any thread, cheap).
    var musicActive: Bool { musicBox.get() }
    /// The mode currently shown: the music mode, or the idle mode once the crossfade passes halfway.
    var activeMode: GlowMode { modeBox.get() }

    func update(_ c: GlowConfig) { cfg.set(c); wakeIfSlow() }

    func flash(times: Int) { flashReq.update { $0 += max(0, min(times, 12)) }; wakeIfSlow() }

    /// Takes over the backlight (BacklightDriver.takeOver) and starts the render loop.
    func start() {
        ctl.lock(); defer { ctl.unlock() }
        guard !started else { return }
        let d = BacklightDriver.shared
        let c = cfg.get()
        // Without a built-in backlight the engine can still drive a Logitech keyboard; driver calls are no-ops then.
        guard d.isAvailable || c.logitech else { statusBox.set(.unavailable("Keyboard backlight not available")); return }
        started = true
        if d.isAvailable && c.enabled && c.mode != .off { d.takeOver(keepAwake: c.keepAwake) }
        keys.set(KeyState())
        keyToken = KeyBus.shared.subscribe { [keys, weak self] e in
            self?.wakeIfSlow()
            guard e.down, !e.isRepeat, e.kind != .modifier, e.kind != .fn, e.kind != .capsLock else {
                if !e.down { keys.update { Self.setDown(&$0, e.keyCode, false) } }
                return
            }
            keys.update { s in
                if Self.isDown(s, e.keyCode) { return }       // OS auto-repeat without the flag
                Self.setDown(&s, e.keyCode, true)
                s.count &+= 1; s.lastPress = e.time
            }
        }
        onsetQ.update { $0.items.removeAll(keepingCapacity: true); $0.lastCount = FeatureBus.shared.latest().onsetCount }
        featToken = FeatureBus.shared.subscribe { [onsetQ, weak self] f in
            if !f.silent || f.onsetCount != 0 { self?.wakeIfSlow() }
            onsetQ.update { q in
                guard f.onsetCount != q.lastCount else { return }
                q.lastCount = f.onsetCount
                // lastOnsetTime is an estimate that precedes the detecting frame; keep it sane.
                let t = f.lastOnsetTime > 0 ? min(max(f.lastOnsetTime, f.time - 0.06), f.time) : f.time
                if q.items.count < 64 { q.items.append(GlowOnset(time: t, strength: f.onsetStrength > 0 ? f.onsetStrength : 1)) }
            }
        }
        r = Renderer()
        rLogi = Renderer(); logiOn = false
        if c.enabled && c.logitech {
            let lb = LogitechBacklight.shared
            DispatchQueue.global(qos: .utility).async { if !lb.isConnected { lb.discover() } }
        }
        r.owned = d.isTakenOver
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let saver = PowerState.shared.saver
        timerSaver = saver
        timerHz = saver ? 60 : 240; slowFlag.set(false); idleSince = 0; lastOutSeen = -2
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / timerHz),
                   leeway: .microseconds(saver ? 1000 : 100))
        t.setEventHandler { [unowned self] in self.tick() }
        timer = t
        statusBox.set(.running)
        t.resume()
    }

    /// Stops the loop and restores the user's backlight. With `quitting` the Logitech hand-back is left to
    /// `LogitechBacklight.restoreForQuit()`, which the quit path runs once afterwards.
    func stop(quitting: Bool = false) {
        ctl.lock(); defer { ctl.unlock() }
        guard started else { return }
        started = false
        timer?.cancel(); timer = nil
        if let k = keyToken { KeyBus.shared.unsubscribe(k); keyToken = nil }
        if let k = featToken { FeatureBus.shared.unsubscribe(k); featToken = nil }
        queue.sync { }                       // wait for an in-flight frame
        SystemLoad.shared.setActive(false); heartSampling = false
        AudioAnalyzer.setOnsetDemand(.glow, false); onsetDemand = false
        BacklightDriver.shared.restore()
        if !quitting {
            if logiOn { LogitechBacklight.shared.release() }
            if logiOn || logiEverOn { LogitechBacklight.shared.restore() }
            logiEverOn = false
        }
        logiOn = false
        modeBox.set(.off)
        levelBox.set(0); fpsBox.set(0); musicBox.set(false)
        statusBox.set(.stopped)
    }

    private static func isDown(_ s: KeyState, _ code: UInt16) -> Bool {
        guard code < 256 else { return false }
        let bit = UInt64(1) << UInt64(code & 63)
        switch code >> 6 { case 0: return s.down.0 & bit != 0; case 1: return s.down.1 & bit != 0
        case 2: return s.down.2 & bit != 0; default: return s.down.3 & bit != 0 }
    }
    private static func setDown(_ s: inout KeyState, _ code: UInt16, _ on: Bool) {
        guard code < 256 else { return }
        let bit = UInt64(1) << UInt64(code & 63)
        func f(_ w: inout UInt64) { if on { w |= bit } else { w &= ~bit } }
        switch code >> 6 { case 0: f(&s.down.0); case 1: f(&s.down.1); case 2: f(&s.down.2); default: f(&s.down.3) }
    }

    // MARK: frame

    private func tick() {
        let now = hostNow()
        let c = cfg.get()
        let ks = keys.get()
        let latest = FeatureBus.shared.latest()
        let delay = SyncClock.shared.delay
        let f = FeatureBus.shared.delayed(delay, now: now)
        let live = !latest.silent && now - latest.time < 0.6
        var onsets: [GlowOnset] = []
        onsetQ.update { q in if !q.items.isEmpty { onsets = q.items; q.items.removeAll(keepingCapacity: true) } }
        var flashes = 0
        if flashReq.get() > 0 { flashReq.update { flashes = $0; $0 = 0 } }
        let d = BacklightDriver.shared
        // CPU-driven heart rate: sample system load only while the heartbeat mode can be on screen.
        let heartUse = c.enabled && c.heartFollowsCPU && (c.mode == .heartbeat || (c.autoActive && c.idleMode == .heartbeat))
        if heartUse != heartSampling { heartSampling = heartUse; SystemLoad.shared.setActive(heartUse) }
        let heartBpm = heartUse ? SystemLoad.shared.bpm : 0
        let onsetUse = c.enabled && Self.onsetModes.contains(c.mode)
        if onsetUse != onsetDemand { onsetDemand = onsetUse; AudioAnalyzer.setOnsetDemand(.glow, onsetUse) }
        // The Logitech renderer starts each frame from the main renderer's heart and ambient phases (pre-step),
        // so both keyboards breathe and beat together.
        let sharedPhases = (r.music.heartPhase, r.music.heartBpm, r.music.ambT, r.idle.heartPhase, r.idle.heartBpm, r.idle.ambT)
        let out = r.step(now: now, cfg: c, f: f, live: live, onsets: onsets, delay: delay, ks: ks,
                         newFlashes: flashes, driver: d, heartBpm: heartBpm)
        levelBox.set(out ?? d.savedBrightness)

        // Logitech keyboard: render ahead by the measured Bluetooth round trip, send the newest level.
        let lb = LogitechBacklight.shared
        if c.logitech && lb.isConnected {
            let lead = lb.leadSeconds
            let dL = max(0, delay - lead)
            let fL = FeatureBus.shared.delayed(dL, now: now)
            logiOut.released = false
            rLogi.music.heartPhase = sharedPhases.0; rLogi.music.heartBpm = sharedPhases.1; rLogi.music.ambT = sharedPhases.2
            rLogi.idle.heartPhase = sharedPhases.3; rLogi.idle.heartBpm = sharedPhases.4; rLogi.idle.ambT = sharedPhases.5
            _ = rLogi.step(now: now, cfg: c, f: fL, live: live, onsets: onsets, delay: dL, ks: ks,
                           newFlashes: flashes, driver: logiOut, heartBpm: heartBpm)
            if logiOut.released { if logiOn { lb.release(); logiOn = false } }
            else if logiOut.wrote { lb.push(GlowEngine.toPerceived(logiOut.light)); logiOn = true; logiEverOn = true; logiOut.wrote = false }
        } else if logiOn {
            lb.release(); logiOn = false; rLogi = Renderer()
        }
        if c.logitech && c.enabled && !lb.isConnected && now - lastPollAt >= 1 { lastPollAt = now; lb.pollDiscover() }
        musicBox.set(r.musicActive)
        modeBox.set(r.activeMode)
        // Idle: no audio, no key activity, output unchanged for 0.5 s -> 30 Hz until input wakes the timer.
        let keyChanged = ks.count != lastKeyCountSeen
        lastKeyCountSeen = ks.count
        let o = out ?? -1
        let busy = live || !onsets.isEmpty || flashes > 0 || keyChanged || abs(o - lastOutSeen) > 1e-4
        lastOutSeen = o
        if busy { idleSince = 0 } else if idleSince == 0 { idleSince = now }
        let idle = idleSince > 0 && now - idleSince >= 0.75
        // On battery / Low Power Mode an active frame rate above 60 Hz is not worth its wakeups.
        let saver = PowerState.shared.saver
        let want = idle ? Self.idleHz : (saver ? min(r.wantedHz, 60) : r.wantedHz)
        if (want != timerHz || saver != timerSaver), let t = timer {
            timerHz = want; timerSaver = saver
            let leewayUs = idle ? (saver ? 4000 : 500) : (saver ? 1000 : 100)
            t.schedule(deadline: .now() + .nanoseconds(1_000_000_000 / timerHz), repeating: .nanoseconds(1_000_000_000 / timerHz),
                       leeway: .microseconds(leewayUs))
            slowFlag.set(idle)
        }
        if r.frames >= 120 || now - r.fpsT0 >= 1 {
            if r.fpsT0 > 0 { fpsBox.set(Double(r.frames) / max(now - r.fpsT0, 1e-3)) }
            r.fpsT0 = now; r.frames = 0
        }
        r.frames += 1
    }

    // MARK: music detection

    /// Hysteretic "is music playing" detector. Active once the delayed features have been loud for
    /// >= 1.5 s cumulative within the last 2 s; inactive after >= 4 s without any loud frame.
    /// Fixed-size state, no allocation after init.
    struct MusicDetector {
        static let binDur = 0.1
        static let bins = 20                  // 2 s window
        static let onSeconds: Float = 1.5
        static let offSeconds = 4.0
        static let threshold: Float = 0.03
        private var loud = [Float](repeating: 0, count: MusicDetector.bins)
        private var lastBin = Int.min
        private var lastLoud = 0.0
        private(set) var active = false

        mutating func update(now: Double, dt: Double, silent: Bool, level: Float) {
            let isLoud = !silent && level > Self.threshold
            let bin = Int(now / Self.binDur)
            if lastBin == Int.min { lastBin = bin }
            if bin > lastBin {
                for i in 1...min(bin - lastBin, Self.bins) { loud[(lastBin + i) % Self.bins] = 0 }
                lastBin = bin
            }
            if isLoud { loud[bin % Self.bins] += Float(dt); lastLoud = now }
            if active {
                if now - lastLoud >= Self.offSeconds {
                    active = false
                    for i in 0..<Self.bins { loud[i] = 0 }
                }
            } else {
                var sum: Float = 0
                for i in 0..<Self.bins { sum += loud[i] }
                if sum >= Self.onSeconds { active = true }
            }
        }
    }

    // MARK: renderer state

    /// Everything one mode needs, kept separate per slot (music / idle) so a slot that was hidden
    /// does not replay stale flares when it returns.
    struct Slot {
        var beat = GlowFlare(), strobe = GlowFlare(), key = GlowFlare()
        var pending: [(fireAt: Double, strength: Float)] = {
            var a = [(fireAt: Double, strength: Float)](); a.reserveCapacity(64); return a
        }()
        var bassEnv: Float = 0, highEnv: Float = 0, heatEnv: Float = 0
        var lastStrobeAt = -1e9
        var ambT: Double = 0
        var heartPhase: Double = 0       // beats, wrapped to 0..<1: continuous while the rate changes
        var heartBpm: Double = 0         // smoothed rate actually used (0 = not started)
        var sleepStart: Double = 0, sleepPhase: Double = .pi / 2
        var lastMode: GlowMode = .off
        var lastRender: Double = 0
        var wasVisible = false
        var fallbackMix: Float = 0       // quiet idle-breathe fallback (auto switch off only)

        mutating func resetEphemeral() {
            beat = GlowFlare(); strobe = GlowFlare(); key = GlowFlare()
            pending.removeAll(keepingCapacity: true)
            bassEnv = 0; highEnv = 0; heatEnv = 0; lastStrobeAt = -1e9; fallbackMix = 0
        }

        struct Ctx {
            var now: Double, dt: Double
            var c: GlowConfig
            var f: AudioFeatures
            var onsets: [GlowOnset]
            var delay: Double
            var heat: Float
            var keyEvent: Bool, keyAt: Double
            var overlayV: Float, flashActive: Bool
            var visible: Bool
            var fallback: Bool, silentLong: Bool
            var heartBpm: Double         // CPU-driven target rate, or 0 for the fixed resting rate
        }

        /// Perceived level (0...1, range-mapped, sleep-scaled) for `mode`.
        mutating func render(_ mode: GlowMode, _ x: Ctx) -> Float {
            let now = x.now, dt = x.dt, c = x.c, f = x.f
            if now - lastRender > 0.25 { resetEphemeral() }
            lastRender = now
            if mode != lastMode { lastMode = mode; sleepStart = now; sleepPhase = .pi / 2; pending.removeAll(keepingCapacity: true) }
            if x.visible && !wasVisible { sleepStart = now; sleepPhase = .pi / 2 }
            wasVisible = x.visible
            ambT += dt * Double(min(max(c.speed, 0.25), 4))
            if mode == .off { return 0 }

            let lo = min(max(c.floor, 0), 1), hi = max(lo, min(max(c.ceiling, 0), 1))
            let pLo = GlowEngine.toPerceived(lo), pHi = GlowEngine.toPerceived(hi)
            let speed = min(max(c.speed, 0.25), 4)
            let sens = min(max(c.sensitivity, 0.25), 3)

            if x.keyEvent && mode == .keyPulse { key.fire(now: now, at: x.keyAt, peak: 1, att: 0.010, dur: 0.20 / Double(speed)) }

            // schedule new onsets at capture time + delay (lookahead); drop them outside onset modes
            let onsetMode = mode == .beatPulse || mode == .beatStrobe || mode == .metronome
            if onsetMode { for o in x.onsets { pending.append((o.time + x.delay, o.strength)) } }
            else if !pending.isEmpty { pending.removeAll(keepingCapacity: true) }

            var L: Float = 0
            switch mode {
            case .beatPulse, .beatStrobe, .metronome:
                let att = mode == .beatStrobe ? 0.006 : 0.010
                var i = 0
                while i < pending.count {
                    let p = pending[i]
                    if p.fireAt - att > now { i += 1; continue }          // not yet: peak lands at fireAt
                    pending.remove(at: i)
                    let start = p.fireAt - att
                    if mode == .beatStrobe {
                        if p.fireAt - lastStrobeAt > 0.12 {
                            lastStrobeAt = p.fireAt
                            strobe.fire(now: now, at: start, peak: 1, att: att, dur: 0.10 / Double(speed), k: 3.2)
                        }
                    } else if mode == .metronome && f.bpm > 40 {
                        // BPM-locked: onsets ignored while a tempo is known
                    } else {
                        let g = GlowShape.clamp01(p.strength * sens * 1.25)
                        var dur = 0.24 + 0.14 * Double(g)
                        if f.bpm > 40 { dur = min(dur, 0.8 * 60.0 / Double(f.bpm)) }
                        beat.fire(now: now, at: start, peak: 1, att: att, dur: dur / Double(speed))
                    }
                }
                if pending.count > 32 { pending.removeFirst(pending.count - 32) }
                if mode == .beatPulse { L = beat.value(now) }
                else if mode == .beatStrobe { L = strobe.value(now) }
                else if f.bpm > 40 {
                    // f is the frame heard `delay` ago; advance its phase to the moment being shown
                    let ph = Double(f.beatPhase) + (now - x.delay - f.time) * Double(f.bpm) / 60
                    let p = ph - floor(ph)
                    L = GlowShape.release(Float(min(p * Double(speed) * 1.6, 1)), 3.0)
                } else { L = beat.value(now) }
            case .bassFollow:
                let v = GlowShape.clamp01(max(f.bass, f.sub * 0.9) * sens)
                bassEnv = follow(bassEnv, powf(v, 1.3), dt, att: 0.012, rel: 0.16 / Double(speed))
                L = bassEnv
            case .spectrum:
                let b = powf(GlowShape.clamp01(max(f.bass, f.sub * 0.9) * sens), 1.3)
                let h = powf(GlowShape.clamp01(f.high * sens), 1.2)
                bassEnv = follow(bassEnv, b, dt, att: 0.012, rel: 0.16 / Double(speed))
                highEnv = follow(highEnv, h, dt, att: 0.008, rel: 0.08 / Double(speed))
                L = min(1, 0.7 * bassEnv + 0.3 * highEnv)
            case .keyPulse:
                L = key.value(now)
            case .typingHeat:
                let tgt = 1 - expf(-0.25 * x.heat * sens)
                heatEnv = follow(heatEnv, tgt, dt, att: 0.05, rel: 0.05)
                L = heatEnv
            case .heartbeat:
                // Rate eases toward the target over a few beats (tau 3 s) and the phase is integrated, so a rate
                // change never jumps mid-beat. The beat shape is squeezed a little at high rates so it still fits.
                let target = x.heartBpm > 0 ? x.heartBpm : 60.0 / GlowShape.heartPeriod
                heartBpm = heartBpm <= 0 ? target : heartBpm + (target - heartBpm) * (1 - exp(-dt / 3))
                heartPhase += dt * Double(speed) * heartBpm / 60
                heartPhase -= floor(heartPhase)
                let span = min(GlowShape.heartPeriod, max(0.62, 1.44 * 60 / heartBpm))
                L = GlowShape.heartbeat(heartPhase * span)
            case .steady, .breathe, .candle, .aurora, .lightning:
                L = GlowShape.ambient(mode, ambT, steady: GlowShape.clamp01(c.steadyLevel))
            case .sleep:
                let T = Double(max(c.sleepMinutes, 0.05)) * 60
                let u = min((now - sleepStart) / T, 1)
                sleepPhase += dt * (0.25 - 0.15 * u) * 2 * .pi     // 4 s breath slowing to 10 s
                L = GlowShape.sleepBreath(sleepPhase)
            case .off: break
            }

            // auto switch off: music modes fall back to a quiet idle breathe after 5 s of silence
            if x.fallback && musicModes.contains(mode) {
                let target: Float = x.silentLong ? 1 : 0
                let step = Float(dt / 1.2)
                fallbackMix += max(-step, min(step, target - fallbackMix))
                if fallbackMix > 0 { L = L + (GlowShape.idleBreathe(now) - L) * GlowShape.ssf(fallbackMix) }
            } else { fallbackMix = 0 }

            if c.keyFlash || mode == .keyPulse || x.flashActive { L = max(L, x.overlayV) }

            var p = pLo + (pHi - pLo) * GlowShape.clamp01(L)
            if mode == .sleep {
                let T = Double(max(c.sleepMinutes, 0.05)) * 60
                let u = (now - sleepStart) / T
                p *= Float(max(0, min(1, (1 - u) / 0.97)))
            }
            return p
        }

        private func follow(_ cur: Float, _ tgt: Float, _ dt: Double, att: Double, rel: Double) -> Float {
            let tau = tgt > cur ? att : rel
            return cur + (tgt - cur) * Float(1 - exp(-dt / tau))
        }
    }

    static let fadeSeconds = 1.2

    /// Render rate for what is on screen: 240 Hz for music/key-reactive modes (10 ms attacks), 120 Hz for
    /// lightning and while a key-flash overlay can fire, 60 Hz for the slow ambient modes.
    static func renderHz(_ c: GlowConfig, mixIdle: Float, flash: Bool) -> Int {
        func hz(_ m: GlowMode) -> Int {
            switch m {
            case .beatPulse, .bassFollow, .beatStrobe, .metronome, .spectrum, .keyPulse, .typingHeat: return 240
            case .lightning: return 120
            default: return 60
            }
        }
        var r = 0
        if !c.autoActive || mixIdle < 1 { r = hz(c.mode) }
        if c.autoActive && mixIdle > 0 { r = max(r, hz(c.idleMode)) }
        if c.keyFlash || flash { r = max(r, 120) }
        return max(r, 60)
    }

    struct Renderer {
        var owned = false
        var lastNow: Double = 0
        var fpsT0: Double = 0
        var frames = 0
        var overlay = GlowFlare()
        var music = Slot(), idle = Slot()
        var detector = MusicDetector()
        var seenKeys: UInt64 = .max
        var heat: Float = 0
        var lastKeepAwake = true
        var lastAudio: Double = 0
        var mixIdle: Float = 0           // 0 = music slot, 1 = idle slot
        var flashLeft = 0, nextFlash: Double = 0, flashUntil: Double = 0
        var smooth: Float = 0            // final perceived output after fall smoothing
        var entryPending = true          // next rendered frame starts from the user's own level
        var entryBase: Float = 0, entry: Float = 1
        var wantedHz = 240               // render rate for the mode on screen
        var lastPerceived: Float = 0     // for tests/UI: perceived level written last
        var musicActive = false
        var activeMode: GlowMode = .off

        /// `f`: features already shifted by the sync delay.
        /// `onsets`: raw capture-time onsets since the last frame; they are scheduled at time + delay.
        /// Returns the drive level written, or nil when the backlight is left to the user.
        mutating func step(now: Double, cfg c: GlowConfig, f: AudioFeatures, live: Bool, onsets: [GlowOnset],
                           delay: Double, ks: KeyState, newFlashes: Int, driver: GlowOutput, heartBpm: Double = 0) -> Float? {
            let dt = lastNow == 0 ? 1.0 / 120 : min(max(now - lastNow, 0.0005), 0.05)
            lastNow = now
            if lastAudio == 0 { lastAudio = now }
            if seenKeys == .max { seenKeys = ks.count }

            detector.update(now: now, dt: dt, silent: f.silent, level: f.level)
            musicActive = detector.active
            if c.autoActive {
                let target: Float = detector.active ? 0 : 1
                let step = Float(dt / GlowEngine.fadeSeconds)
                mixIdle += max(-step, min(step, target - mixIdle))
            } else { mixIdle = 0 }
            activeMode = c.autoActive && mixIdle >= 0.5 ? c.idleMode : c.mode

            // test flashes
            if newFlashes > 0 { flashLeft += newFlashes; if nextFlash < now { nextFlash = now } }
            if flashLeft > 0 && now >= nextFlash {
                overlay.fire(now: now, at: now, peak: 1, att: 0.010, dur: 0.14)
                flashLeft -= 1; nextFlash = now + 0.22; flashUntil = now + 0.17
            }
            let flashActive = flashLeft > 0 || now < flashUntil

            // settled on a slot whose mode is .off: leave the backlight to the user
            let slotOff = (mixIdle <= 0 && c.mode == .off) || (mixIdle >= 1 && c.idleMode == .off)
            let wantOff = !c.enabled || slotOff
            if wantOff && !flashActive {
                if owned {
                    // ease to the user's own level first so handing the backlight back does not pop
                    let pb = GlowEngine.toPerceived(BacklightDriver.lightFor(driver.savedBrightness))
                    if abs(smooth - pb) > 0.01 {
                        smooth += (pb - smooth) * Float(1 - exp(-dt / 0.4))
                        let out = GlowEngine.toDrive(smooth)
                        driver.writeLight(out)
                        return out
                    }
                    driver.restore(); owned = false
                }
                smooth = 0; entryPending = true
                return nil
            }
            if !owned || !driver.isTakenOver { driver.takeOver(keepAwake: c.keepAwake); owned = true; lastKeepAwake = c.keepAwake }
            if c.keepAwake != lastKeepAwake { driver.setKeepAwake(c.keepAwake); lastKeepAwake = c.keepAwake }

            let lo = min(max(c.floor, 0), 1), hi = max(lo, min(max(c.ceiling, 0), 1))
            let pHi = GlowEngine.toPerceived(hi)
            if entryPending {      // glide from the user's level into the mode instead of popping
                entryPending = false
                entryBase = GlowEngine.toPerceived(BacklightDriver.lightFor(driver.savedBrightness))
                smooth = entryBase; entry = 0
            }

            // key events (local: never delayed)
            var keyEvent = false, keyAt = now
            if ks.count != seenKeys {
                let n = Int(min(ks.count &- seenKeys, 50)); seenKeys = ks.count
                heat += Float(n)
                keyEvent = true
                keyAt = ks.lastPress > 0 ? ks.lastPress : now
                let speed = min(max(c.speed, 0.25), 4)
                if c.keyFlash && activeMode != .keyPulse {
                    overlay.fire(now: now, at: keyAt, peak: 0.9, att: 0.010, dur: 0.17 / Double(speed))
                }
            }
            heat *= expf(-Float(dt) / 4)

            if wantOff {   // only a test flash is showing: sit at the user's level and flash above it
                let base = BacklightDriver.lightFor(driver.savedBrightness)
                let pb = GlowEngine.toPerceived(base), pt = max(pHi, pb)
                let out = GlowEngine.toDrive(pb + (pt - pb) * overlay.value(now))
                driver.writeLight(out)
                return out
            }

            if live { lastAudio = now }
            let ov = overlay.value(now)
            var x = Slot.Ctx(now: now, dt: dt, c: c, f: f, onsets: onsets, delay: delay, heat: heat,
                             keyEvent: keyEvent, keyAt: keyAt, overlayV: ov, flashActive: flashActive,
                             visible: true, fallback: !c.autoActive, silentLong: now - lastAudio > 5,
                             heartBpm: heartBpm)
            // The music slot always runs (it stays warm so the first beats after a switch are not missed);
            // the idle slot only runs with auto switch on.
            x.visible = !c.autoActive || mixIdle < 1
            let pm = music.render(c.mode, x)
            var p = pm
            if c.autoActive {
                x.visible = mixIdle > 0
                let pi = idle.render(c.idleMode, x)
                p = pm + (pi - pm) * GlowShape.ssf(mixIdle)
            }

            wantedHz = GlowEngine.renderHz(c, mixIdle: mixIdle, flash: flashActive)
            if entry < 1 {
                entry = min(1, entry + Float(dt / 1.0))
                p = entryBase + (p - entryBase) * GlowShape.ssf(entry)
            }

            // output smoothing: rises pass through untouched, falls get a short one-pole (removes stair-steps)
            if p >= smooth { smooth = p } else { smooth += (p - smooth) * Float(1 - exp(-dt / 0.008)) }
            lastPerceived = smooth
            let out = GlowEngine.toDrive(smooth)
            driver.writeLight(out)
            return out
        }
    }

    // MARK: UI preview

    /// Pure function used by the UI mode-card previews: level for `mode` at time `t` with
    /// synthetic input (kick at 120 BPM, typing bursts). Output 0...1 at floor 0 / ceiling 1.
    static func previewLevel(mode: GlowMode, t: Double) -> Float {
        let beatP = t - floor(t / 0.5) * 0.5               // 120 BPM
        let kick = GlowShape.env(beatP, att: 0.010, dur: 0.34)
        switch mode {
        case .beatPulse: return kick
        case .beatStrobe: return GlowShape.env(beatP, att: 0.006, dur: 0.10, k: 3.2)
        case .metronome: return GlowShape.release(Float(min(beatP * 1.6 / 0.5, 1)), 3.0)
        case .bassFollow:
            let b = expf(Float(-beatP * 7))
            return powf(b, 1.3) * Float(GlowShape.ss(beatP / 0.015))
        case .spectrum:
            let b = powf(expf(Float(-beatP * 7)), 1.6) * Float(GlowShape.ss(beatP / 0.015))
            let hp = t + 0.25 - floor((t + 0.25) / 0.5) * 0.5
            return min(1, 0.7 * b + 0.3 * 0.8 * expf(Float(-hp * 22)))
        case .keyPulse:
            let burst = floor(t / 3.2), local = t - burst * 3.2
            let j = min(floor(local / 0.15), 7)
            return GlowShape.env(local - j * 0.15, att: 0.010, dur: 0.20)
        case .typingHeat:
            let burst = Int(floor(t / 3.2))
            var heat: Float = 0
            for b in max(0, burst - 4)...max(0, burst) {
                for j in 0..<8 {
                    let ti = Double(b) * 3.2 + Double(j) * 0.15
                    if ti <= t { heat += expf(Float(-(t - ti) / 4)) }
                }
            }
            return 1 - expf(-0.25 * heat)
        case .steady: return 0.6
        case .breathe, .heartbeat, .candle, .aurora, .lightning:
            return GlowShape.ambient(mode, t, steady: 0.6)
        case .sleep:
            let cyc = 14.0, u = (t - floor(t / cyc) * cyc) / cyc
            return GlowShape.sleepBreath(t * 2 * .pi * 0.2) * Float(max(0, 1 - u))
        case .off: return 0
        }
    }
}
