// HapticGlow - haptic voice mixer + realtime-ish scheduler for the Force Touch trackpad.
// Voice shapes ported from nospeaker (MIT, os6 / Cody Collier): thump f(t)=f_end+(f_start-f_end)exp(-t/0.02),
// level^0.45 perceptual curve, two-tone (a1, 1.8*a2) weighting, 2.7-4.3 kHz fricative bursts, absolute-deadline
// cycle-aligned segments.
//
// Quiet + synced (this revision): kick voices are rendered by MusicPlanner's `Voice` (low rounded thump, all
// tones <= HapticTuning.quietMaxHz when HapticConfig.quiet), and every music-driven haptic is scheduled at
// captureTime + SyncClock.delay - motorLatency (kick mode: pending queue; bass/full/music: FeatureDelayLine).
import Foundation
import Darwin

final class HapticEngine: @unchecked Sendable {
    static let shared = HapticEngine()

    // MARK: shared state (lock-protected hand-off)
    private let lock = UnfairLock()
    private var cfg = HapticConfig()
    /// Mode picked by AudioSourceMonitor; applies while `cfg.autoSource` is on and the chosen mode is music or movie.
    private var autoMode: HapticMode = .music
    private var _status: EngineStatus = .stopped
    private var running = false
    private var thread: Thread?
    /// Scheduler generation: a thread loops only while its id is current, so stop()/start() never leaves two running.
    private var gen = 0
    private var featToken = 0, keyToken = 0
    /// Wakes the scheduler out of its idle (haptics off) sleep when config or a test thump changes.
    private let idleWake = DispatchSemaphore(value: 0)

    // Inputs written by bus listeners (audio / key threads), read by the scheduler.
    private let inLock = UnfairLock()
    private var inFeat = AudioFeatures()
    private var inOnsetCount: UInt64 = 0
    private var inOnsetStrength: Float = 0
    private var inTaps: [KeyEvent] = []
    private var inTestThump = false
    private var inEvents: [MusicEvent] = { var a = [MusicEvent](); a.reserveCapacity(32); return a }()
    private var inFeed = MusicEventFeed()
    private var inLine = FeatureDelayLine()
    private var inMovieActive = false
    private var inMovieFrames: [AudioFeatures] = { var a = [AudioFeatures](); a.reserveCapacity(64); return a }()
    private let planner = MusicPlanner()
    private let moviePlanner = MoviePlanner()
    /// Per-layer actuation counts of the music planner: kick, kickWave, snare, hat, texture, melody.
    var musicLayerCounts: [UInt64] { countsBox.get() }
    /// Copy of the planner counts, published by the scheduler thread.
    private let countsBox = Locked<[UInt64]>([UInt64](repeating: 0, count: 6))

    var status: EngineStatus { lock.withLock { _status } }
    private let apsBox = Locked<Double>(0)
    var actuationsPerSecond: Double { apsBox.get() }

    // Diagnostics: scheduler lateness vs absolute deadline (microseconds), ring buffer.
    private let latLock = UnfairLock()
    private var latRing = [Float](repeating: 0, count: 8192)
    private var latCount = 0
    var latenessSamplesUs: [Float] { latLock.withLock { Array(latRing[0..<min(latCount, latRing.count)]) } }
    func resetLatencyStats() { latLock.withLock { latCount = 0 } }

    // MARK: lifecycle

    /// Opens the motor, subscribes to FeatureBus/KeyBus, starts the realtime scheduler thread.
    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        let c = cfg
        lock.unlock()
        guard TrackpadMotor.shared.open(preferExternal: c.preferExternal)
                || (c.preferExternal && TrackpadMotor.shared.open(preferExternal: false)) else {
            lock.withLock { _status = .unavailable("No Force Touch trackpad") }
            return
        }
        lock.lock()
        running = true
        gen += 1
        let g = gen
        _status = .running
        lock.unlock()
        let am0 = lock.withLock { autoMode }
        inLock.withLock { inMovieActive = (c.enabled && Self.resolved(c, auto: am0).mode == .movie); inMovieFrames.removeAll(keepingCapacity: true) }
        featToken = FeatureBus.shared.subscribe { [weak self] f in self?.onFeatures(f) }
        keyToken = KeyBus.shared.subscribe { [weak self] e in self?.onKey(e) }
        let t = Thread { [weak self] in self?.runLoop(gen: g) }
        t.name = "HapticGlow.haptics"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        lock.withLock { thread = t }
        t.start()
    }

    func stop() {
        lock.lock()
        let was = running
        running = false
        gen += 1
        thread = nil
        if _status == .running || _status == .starting { _status = .stopped }
        lock.unlock()
        idleWake.signal()
        guard was else { return }
        FeatureBus.shared.unsubscribe(featToken)
        KeyBus.shared.unsubscribe(keyToken)
    }

    func update(_ new: HapticConfig) {
        let old: HapticConfig = lock.withLock { let o = cfg; cfg = new; return o }
        defer { idleWake.signal() }
        // Only an explicit user toggle resets the governor; Auto source flips never do.
        if old.enabled != new.enabled || old.mode != new.mode { TrackpadMotor.shared.resetGovernor() }
        let am = lock.withLock { autoMode }
        inLock.withLock {
            inMovieActive = (new.enabled && Self.resolved(new, auto: am).mode == .movie)
            if !inMovieActive { inMovieFrames.removeAll(keepingCapacity: true) }
        }
        if old.preferExternal != new.preferExternal, lock.withLock({ running }) {
            if !TrackpadMotor.shared.open(preferExternal: new.preferExternal) {
                _ = TrackpadMotor.shared.open(preferExternal: old.preferExternal)
            }
        }
    }

    /// After system wake the actuator handle may be stale: close and re-open it and clear the stall latch.
    func reopenMotor() {
        guard lock.withLock({ running }) else { return }
        TrackpadMotor.shared.reopen()
        idleWake.signal()
    }

    /// Effective config: with Auto on, music/movie follow the detected source.
    private static func resolved(_ c: HapticConfig, auto: HapticMode) -> HapticConfig {
        guard c.autoSource, c.mode == .music || c.mode == .movie else { return c }
        var r = c
        r.mode = auto == .movie ? .movie : .music
        return r
    }

    /// Called by AudioSourceMonitor when the detected source changes the Auto choice.
    func setAutoMode(_ m: HapticMode) {
        let (changed, c): (Bool, HapticConfig) = lock.withLock {
            let ch = autoMode != m; autoMode = m; return (ch, cfg)
        }
        guard changed else { return }
        inLock.withLock {
            inMovieActive = (c.enabled && Self.resolved(c, auto: m).mode == .movie)
            if !inMovieActive { inMovieFrames.removeAll(keepingCapacity: true) }
        }
        idleWake.signal()
    }

    /// Fire one kick thump at the current strength (test button).
    func testThump() {
        inLock.withLock { inTestThump = true }
        idleWake.signal()
        if !lock.withLock({ running }) {
            // Not running (engine off): run just long enough to play it.
            start()
            let t = Thread { [weak self] in
                Thread.sleep(forTimeInterval: 0.5)
                if let self, !self.cfgEnabledForRun() { self.stop() }
            }
            t.start()
        }
    }
    private func musicMode0(_ c: HapticConfig) -> Bool { c.enabled && c.mode == .music }   // c is already resolved
    /// Governor snapshot of the motor (duty, rate, throttling, stall). See `MotorGovernorStatus`.
    var governorStatus: MotorGovernorStatus { TrackpadMotor.shared.governorStatus }
    private func cfgEnabledForRun() -> Bool { lock.withLock { cfg.enabled && cfg.mode != .off } }

    // MARK: bus listeners (never touch the motor here)

    private func onFeatures(_ f: AudioFeatures) {
        inLock.lock()
        let wasSilent = inFeat.silent
        inFeat = f
        inLine.push(f)
        if !(wasSilent && f.silent) {
            if inMovieActive {
                if inMovieFrames.count < 64 { inMovieFrames.append(f) }
            } else {
                inFeed.ingest(f, into: &inEvents)
                if f.onsetCount != inOnsetCount {
                    inOnsetCount = f.onsetCount
                    inOnsetStrength = max(inOnsetStrength, f.onsetStrength)
                }
            }
        }
        inLock.unlock()
        if wasSilent && !f.silent { idleWake.signal() }   // end of the battery-saver sleep (see runLoop)
    }
    private func onKey(_ e: KeyEvent) {
        guard e.down, !e.isRepeat else { return }
        inLock.lock()
        if inTaps.count < 16 { inTaps.append(e) }
        inLock.unlock()
        idleWake.signal()
    }

    // MARK: scheduler

    private static let tb: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    @inline(__always) private static func toTicks(_ sec: Double) -> UInt64 {
        UInt64(sec * 1e9 * Double(tb.denom) / Double(tb.numer))
    }
    @inline(__always) private static func toSec(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e9
    }

    private func setRealtime(period: Double) {
        var pol = thread_time_constraint_policy_data_t(
            period: UInt32(Self.toTicks(period)),
            computation: UInt32(Self.toTicks(0.0045)),
            constraint: UInt32(Self.toTicks(period)),
            preemptible: 1)
        let kr = withUnsafeMutablePointer(to: &pol) {
            $0.withMemoryRebound(to: integer_t.self, capacity: MemoryLayout<thread_time_constraint_policy_data_t>.size / 4) {
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0,
                                  mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / 4))
            }
        }
        if kr != KERN_SUCCESS { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }
    }

    // Voice state (scheduler thread only).
    private struct PendKick { var due: Double; var amp: Float; var t: Double }
    private struct Tap { var active = false; var due = 0.0; var hz: Float = 120 }

    private func runLoop(gen g: Int) {
        let tick = 0.005   // MTActuationActuate blocks ~3.7 ms per call on M-series, so 2.5 ms ticks are not reachable
        setRealtime(period: tick)
        let motor = TrackpadMotor.shared
        // music mode ticks faster so a tap waits <= 1 ms for the scheduler (the motor call itself throttles bursts)
        let musicTickAC = 0.001, musicTickSaver = 0.0025
        var deadline = mach_absolute_time()
        var evBuf: [MusicEvent] = []; evBuf.reserveCapacity(32)
        var movieBuf: [AudioFeatures] = []; movieBuf.reserveCapacity(64)
        var lastMode = HapticMode.off
        var lastLive = false
        planner.reset(); planner.hasWaveforms = motor.hasWaveforms; planner.impulseOK = true
        moviePlanner.reset()

        var kv = HapticVoice()
        var kickQ: [PendKick] = []; kickQ.reserveCapacity(16)
        var lastKickCap = -1.0
        var tap = Tap()
        // bass
        var bassEnv: Float = 0, bassLog2: Float = 0, bassHave = false, bassDue = 0.0, bassLastT = 0.0
        // full
        var fullDue = 0.0, highPrev: Float = 0, burstUntil = 0.0, burstCool = 0.0, burstDue = 0.0
        var lastFullHz1: Float = 0, lastFullHz2: Float = 0
        // limiter / guards
        var driveStart = 0.0, lastDrive = 0.0
        var lastAct = 0.0
        var backoffUntil = 0.0, fails = 0
        var rng = SystemRandomNumberGenerator()
        var cand: [(hz: Float, lv: Float, ms: Float)] = []
        cand.reserveCapacity(6)
        // actuations/s
        var apsT = Self.toSec(mach_absolute_time()), apsC = motor.actuationCount
        var lastHitNote = 0.0
        var govT = 0.0
        var idleStreak = 0
        var silentSince = 0.0
        var lastLoopSec = apsT

        while lock.withLock({ running && gen == g }) {
            let c = lock.withLock { Self.resolved(cfg, auto: autoMode) }
            let saver = PowerState.shared.saver
            // Haptics off and nothing in flight: sleep on a semaphore (woken by update/testThump/stop) instead of
            // waking every 5 ms. Needs a few quiet ticks first so any off-transition cleanup has run.
            let idleNow = (!c.enabled || c.mode == .off) && !kv.active && !tap.active && kickQ.isEmpty
            idleStreak = idleNow ? min(idleStreak + 1, 8) : 0
            // Battery saver: when audio is silent and nothing is in flight, sleep on the semaphore (woken
            // immediately by the first audible frame, a key press, mode switch or config change) with a 250 ms backstop.
            var saverIdle = false
            let plannerIdle = (c.mode != .music || (planner.isIdle && evBuf.isEmpty))
                && (c.mode != .movie || (moviePlanner.isIdle && movieBuf.isEmpty))
                && (c.mode != .bass || bassEnv < 0.02)
                && (c.mode != .full || lastLoopSec >= burstUntil)
            if !idleNow && c.enabled && c.mode != .off
                && !kv.active && !tap.active && kickQ.isEmpty && plannerIdle {
                let silentNow = inLock.withLock { inFeat.silent && inTaps.isEmpty && !inTestThump && inEvents.isEmpty && inMovieFrames.isEmpty }
                if silentNow {
                    let tCur = Self.toSec(mach_absolute_time())
                    if silentSince == 0 { silentSince = tCur }
                    saverIdle = tCur - silentSince > 0.5
                } else { silentSince = 0 }
            } else { silentSince = 0 }
            var nowT: UInt64
            // On AC the same idle sleep applies in sustained silence; the first audible frame wakes it at once.
            if idleStreak >= 4 || saverIdle {
                _ = idleWake.wait(timeout: .now() + (saver ? 0.25 : 0.1))
                deadline = mach_absolute_time()
                nowT = deadline
                if lock.withLock({ gen != g }) { break }
            } else {
                // On battery in movie mode during quiet dialogue (no pending impacts, no rumble, no sub), 5 ms ticks suffice.
                let movieDialogueSaver = saver && c.enabled && c.mode == .movie && moviePlanner.isIdle && !kv.active && !tap.active
                    && inLock.withLock { inFeat.sub < 0.6 && inMovieFrames.isEmpty }
                let step = (c.enabled && (c.mode == .music || (c.mode == .movie && !movieDialogueSaver))) ? (saver ? musicTickSaver : musicTickAC) : tick
                deadline &+= Self.toTicks(step)
                let overran = mach_absolute_time() > deadline   // previous Actuate blocked past this deadline
                mach_wait_until(deadline)
                nowT = mach_absolute_time()
                if nowT > deadline && !overran {
                    let late = Self.toSec(nowT - deadline)
                    latLock.withLock { latRing[latCount % latRing.count] = Float(late * 1e6); latCount += 1 }
                }
                if nowT > deadline && Self.toSec(nowT - deadline) > 0.05 { deadline = nowT }   // fell far behind: resync
            }

            let now = Self.toSec(nowT)
            lastLoopSec = now

            // pull inputs
            inLock.lock()
            let f = inFeat
            let fTime = (c.mode == .movie) ? moviePlanner.featureTime(now: now) : planner.featureTime(now: now)
            let fd = inLine.at(fTime, fallback: inFeat)   // features as the listener hears them
            let test = inTestThump; inTestThump = false
            if !inEvents.isEmpty { evBuf.append(contentsOf: inEvents); inEvents.removeAll(keepingCapacity: true) }
            if !inMovieFrames.isEmpty { movieBuf.append(contentsOf: inMovieFrames); inMovieFrames.removeAll(keepingCapacity: true) }
            var taps: [KeyEvent] = []
            if !inTaps.isEmpty { taps = inTaps; inTaps.removeAll(keepingCapacity: true) }
            inLock.unlock()

            // stats
            if now - apsT >= 1 {
                let cnt = motor.actuationCount
                apsBox.set(Double(cnt &- apsC) / (now - apsT)); apsC = cnt; apsT = now
            }

            let live = c.enabled
            let strength = max(0, min(1, c.strength))
            motor.quietMode = c.quiet
            motor.allowSpeakerBand = c.mode == .full && !c.quiet
            if now - govT >= 0.25 {
                govT = now
                countsBox.set(planner.counts)
                let g = motor.governorStatus
                if g.stalled {
                    lock.withLock { if _status == .running { _status = .failed("Haptics stopped: \(g.stallReason)") } }
                } else {
                    lock.withLock { if case .failed(let m) = _status, m.hasPrefix("Haptics stopped") { _status = .running } }
                }
            }
            if musicMode0(c) { planner.observe(f) }

            // ---- trigger voices
            let musicMode = live && c.mode == .music
            let movieMode = live && c.mode == .movie
            if c.enabled != lastLive { motor.clearStall() }   // a stale stall latch never outlives a toggle; duty limits stay
            let reEnabled = c.enabled && !lastLive
            lastLive = c.enabled
            if reEnabled && c.mode == .movie { moviePlanner.reset(); movieBuf.removeAll(keepingCapacity: true) }
            if c.mode != lastMode {
                if c.mode == .music { planner.reset(); evBuf.removeAll(keepingCapacity: true) }
                if c.mode == .movie { moviePlanner.reset(); movieBuf.removeAll(keepingCapacity: true) }
                lastMode = c.mode
            }
            if movieMode {
                for mf in movieBuf { moviePlanner.observe(mf) }
                movieBuf.removeAll(keepingCapacity: true)
                if test { moviePlanner.triggerTestImpact(now: now) }
            } else {
                movieBuf.removeAll(keepingCapacity: true)
            }
            if test && c.mode == .music { evBuf.append(MusicEvent(kind: 0, strength: 1, time: now - planner.syncDelay() + HapticTuning.motorLatency)) }
            if !musicMode && !(live && c.mode == .kick) && !evBuf.isEmpty { evBuf.removeAll(keepingCapacity: true) }
            // kick mode: schedule each low-band onset at captureTime + delay - motorLatency (pending queue),
            // merge detections closer than kickMinGap, drop hits later than due + tolerance
            let delay = planner.syncDelay()
            if live && c.mode == .kick {
                for e in evBuf where e.kind == 0 {
                    if e.time - lastKickCap < HapticTuning.kickMinGap { continue }
                    lastKickCap = e.time
                    if kickQ.count < 16 { kickQ.append(PendKick(due: e.time + delay - HapticTuning.motorLatency, amp: max(0.35, powf(max(0, min(1, e.strength)), 0.6)), t: e.time)) }
                }
                evBuf.removeAll(keepingCapacity: true)
            }
            let kLate = delay < HapticTuning.shortDelay ? HapticTuning.lateToleranceShort : HapticTuning.lateTolerance
            kickQ.removeAll { now - $0.due > kLate }
            var kickNow: Float = -1
            if test && (!live || (c.mode != .music && c.mode != .movie)) { kickNow = 1 }   // test thump works in any mode, still governed
            else if let i = kickQ.firstIndex(where: { now >= $0.due }) { kickNow = kickQ[i].amp; kickQ.remove(at: i) }
            if kickNow > 0 {
                let p = max(0, min(1, c.punch)), pt = max(0, min(1, c.pitch))
                kv.start(HapticTuning.kick(c.feel, quiet: c.quiet), amp: kickNow, strength: strength, at: now, quiet: c.quiet,
                         pitchScale: 1 + HapticTuning.pitchSliderRange * (pt - 0.5) * 2,
                         lenScale: 1 + HapticTuning.punchSliderRange * Double((p - 0.5) * 2))
                if now - lastHitNote > 0.02 { HapticBus.shared.noteHit(level: strength * kickNow); lastHitNote = now }
            }
            if live && c.typingTaps, let e = taps.last {
                tap.active = true; tap.due = now
                let hz = e.kind == .space ? 80 : max(90, min(180, 175 - 60 * e.y + 20 * (e.x - 0.5)))
                tap.hz = c.quiet ? min(hz, HapticTuning.quietMaxHz) : hz   // typing taps stay below the audible band in quiet mode
            }

            if now < backoffUntil || now - lastAct < 0.0035 {
                // rate cap / back-off: voices keep their schedule, this tick emits nothing
                continue
            }

            // ---- music mode: layered taps + texture + melody, one actuation per tick
            if musicMode {
                if let act = planner.tick(now: now, f: fd, events: evBuf, cfg: c) {
                    evBuf.removeAll(keepingCapacity: true)
                    let rc = planner.execute(act, on: motor)
                    lastAct = now
                    var soft = rc < 0   // governor refusals are not actuator failures
                    switch act { case .tones: break; default: soft = true }
                    if rc != 0 && !soft { fails += 1; backoffUntil = now + min(1.0, 0.02 * Double(1 << min(6, fails))) } else if rc == 0 { fails = 0 }
                    let lv = planner.lastLevel
                    let isTap = planner.lastLayer != .texture && planner.lastLayer != .melody
                    if now - lastHitNote > (isTap ? 0.02 : 0.03), isTap || lv > 0.25 { HapticBus.shared.noteHit(level: lv); lastHitNote = now }
                    continue
                }
                evBuf.removeAll(keepingCapacity: true)
            }

            // ---- movie mode: LFE impacts + sustained sub-bass rumble, silent during dialogue
            if movieMode {
                if let act = moviePlanner.tick(now: now, f: fd, cfg: c) {
                    let rc = moviePlanner.execute(act, on: motor)
                    lastAct = now
                    var soft = rc < 0
                    switch act { case .tones: break; default: soft = true }
                    if rc != 0 && !soft { fails += 1; backoffUntil = now + min(1.0, 0.02 * Double(1 << min(6, fails))) } else if rc == 0 { fails = 0 }
                    let lv = moviePlanner.lastLevel
                    let isImpact = moviePlanner.lastLayer == .impact
                    if now - lastHitNote > (isImpact ? 0.02 : 0.03), isImpact || lv > 0.20 { HapticBus.shared.noteHit(level: lv); lastHitNote = now }
                    continue
                }
            }

            // ---- collect due voice contributions: (hz, level, ms) ordered by priority
            cand.removeAll(keepingCapacity: true)
            var burst = false
            // tap (highest priority)
            if tap.active && now >= tap.due {
                cand.append((tap.hz, 0.35 * strength, c.quiet ? 1000 / tap.hz : 8))   // quiet: one whole cycle, no mid-wave cut
                tap.active = false
            }
            // kick voice (pre-rendered whole-cycle segments, see HapticVoice)
            if kv.active, let sg = kv.next(now: now), sg.level > 0.01 { cand.append((sg.hz, sg.level, sg.ms)) }
            if live && !test {
                switch c.mode {
                case .bass:
                    // envelope smoothing: fast attack, punch-dependent release
                    let dt = Float(max(0.001, now - bassLastT)); bassLastT = now
                    let raw = max(0, min(1, fd.belowCutoff))
                    let tc: Float = raw > bassEnv ? 0.003 : (0.08 - 0.06 * max(0, min(1, c.punch)))
                    bassEnv += (raw - bassEnv) * (1 - expf(-dt / tc))
                    if now >= bassDue {
                        if bassEnv < 0.02 || fd.silent {
                            bassDue = now + 0.005
                        } else {
                            // fold pitch up into >=110 Hz, plus 0-2 extra octaves
                            // quiet: fold into 40-80 Hz (inaudible); loud: fold up into >=110 Hz plus 0-2 extra octaves
                            let extra = c.quiet ? 0 : Float(min(2, Int(max(0, min(1, c.pitch)) * 3)))
                            var tgt: Float = bassHave ? bassLog2 : log2f(c.quiet ? 60 : 110)
                            if fd.bassPitchHz > 20 {
                                if c.quiet { tgt = log2f(MusicPlanner.fold(fd.bassPitchHz, lo: HapticTuning.textureQuietLo, hi: HapticTuning.textureQuietHi)) }
                                else {
                                    var fb = fd.bassPitchHz
                                    while fb < 110 { fb *= 2 }
                                    tgt = log2f(min(450, fb * powf(2, extra)))
                                }
                            }
                            if !bassHave { bassLog2 = tgt; bassHave = true }
                            else {
                                let maxStep: Float = 0.5 * dt / 0.010
                                let step = (tgt - bassLog2) * 0.3
                                bassLog2 += max(-maxStep, min(maxStep, step))
                            }
                            let hz = exp2f(bassLog2)
                            let cyc = hz >= 200 ? 1.0 : 2.0
                            let seg = c.quiet ? max(1, (0.012 * Double(hz)).rounded()) / Double(hz) : min(0.010, cyc / Double(hz))
                            let lv = strength * powf(bassEnv, 0.45)
                            cand.append((hz, min(0.8 + 0.2 * strength, lv), Float(seg * 1000)))
                            bassDue += seg
                            if bassDue < now { bassDue = now + seg }
                        }
                    }
                case .full:
                    if now >= fullDue {
                        fullDue = now + 0.005
                        let lvIn = max(0, min(1, fd.level))
                        if !fd.silent && lvIn > 0.02 && fd.peaks.y > 0.001 {
                            var h1 = fd.peaks.x, h2 = fd.peaks.z
                            // light smoothing to avoid frequency chatter
                            if lastFullHz1 > 0 { h1 = lastFullHz1 + (h1 - lastFullHz1) * 0.6 }
                            if lastFullHz2 > 0 && h2 > 0 { h2 = lastFullHz2 + (h2 - lastFullHz2) * 0.6 }
                            lastFullHz1 = h1; lastFullHz2 = h2
                            h1 = max(80, min(4000, h1))
                            let lv = strength * powf(lvIn, 0.45)
                            let seg1 = Float(max(1, (0.005 * Double(h1)).rounded()) / Double(h1) * 1000)
                            if h2 > 80 && fd.peaks.w > 0.001 {
                                h2 = min(4000, h2)
                                let seg2 = Float(max(1, (0.005 * Double(h2)).rounded()) / Double(h2) * 1000)
                                cand.append((h1, lv, seg1))
                                cand.append((h2, lv, seg2))
                                // encode weights via amplitude below
                                cand[cand.count - 2].lv = lv * fd.peaks.y
                                cand[cand.count - 1].lv = lv * 1.8 * fd.peaks.w
                                let s = cand[cand.count - 2].lv + cand[cand.count - 1].lv
                                if s > 0 {
                                    // keep both tones' amps relative, but cap overall level at lv
                                    let k = lv / s
                                    cand[cand.count - 2].lv *= k; cand[cand.count - 1].lv *= k
                                }
                            } else {
                                cand.append((h1, lv, seg1))
                            }
                        } else { lastFullHz1 = 0; lastFullHz2 = 0 }
                        // fricative bursts on high-flux transients
                        let flux = fd.high - highPrev; highPrev = fd.high
                        if flux > 0.2 && now > burstCool && fd.high > 0.15 {
                            burstUntil = now + 0.004; burstCool = now + 0.04; burstDue = now
                        }
                        if now >= burstDue && now < burstUntil + 0.001 && burstDue > 0 { burst = true; burstDue = 0 }
                    }
                default: break
                }
            }

            if cand.isEmpty && !burst {
                if now - lastDrive > 0.05 { driveStart = 0 }
                continue
            }

            // ---- mix: priority order, max 2 tones per actuation; amps sum <= 1, level <= 1
            var level: Float = 0
            var segA: MotorSeg?, segB: MotorSeg?, segC: MotorSeg?
            if burst && cand.isEmpty {
                func rf() -> Float { Float.random(in: 2700...4300, using: &rng) }
                segA = MotorSeg(hz: rf(), amp: 1, ms: 4); segB = MotorSeg(hz: rf(), amp: 1, ms: 4); segC = MotorSeg(hz: rf(), amp: 1, ms: 4)
                level = strength * 0.7 * max(0.3, min(1, f.high))
            } else {
                let a = cand[0]
                if cand.count >= 2 {
                    let b = cand[1]
                    // the same-voice pair (full mode) or the top two voices
                    segA = MotorSeg(hz: a.hz, amp: a.lv, ms: a.ms)
                    segB = MotorSeg(hz: b.hz, amp: b.lv, ms: b.ms)
                    level = max(a.lv, b.lv) + 0.3 * min(a.lv, b.lv)
                } else {
                    segA = MotorSeg(hz: a.hz, amp: 1, ms: a.ms)
                    level = a.lv
                }
            }

            // ---- sustained-level limiter: cap ~0.6 after 300 ms of continuous drive
            if level > 0.05 {
                if driveStart == 0 || now - lastDrive > 0.05 { driveStart = now }
                lastDrive = now
                let held = now - driveStart
                if held > 0.3 {
                    let k = Float(min(1, (held - 0.3) / 0.1))
                    level = min(level, 1 - 0.4 * k)
                }
            } else if now - lastDrive > 0.05 { driveStart = 0 }

            level = min(1, max(0, level))
            guard let sa = segA, level > 0.005 else { continue }
            let rc = motor.playSegs(sa, segB, segC, level: level)
            lastAct = now
            if rc > 0 || rc == -1 {   // governor refusals (rc <= -10) are not actuator failures
                fails += 1
                backoffUntil = now + min(1.0, 0.02 * Double(1 << min(6, fails)))
            } else if rc == 0 { fails = 0 }
            if !kv.active && c.mode != .kick, now - lastHitNote > 0.03, level > 0.25 {
                HapticBus.shared.noteHit(level: level); lastHitNote = now
            }
        }
    }
}
