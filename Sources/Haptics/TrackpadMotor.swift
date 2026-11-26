// HapticGlow - Force Touch trackpad motor driver.
// Ported from nospeaker (MIT, os6 / Cody Collier): MultitouchSupport dlopen, actuator open and the
// actuation dictionary format (BaseWaveform amplitude 0, Sine tones summing to 1, loudness = level arg).
import Foundation

struct MotorTone: Sendable { var hz: Float; var amp: Float }

/// One tone segment for the allocation-free path: frequency, relative amplitude, duration in ms.
struct MotorSeg: Sendable { var hz: Float; var amp: Float; var ms: Float }

/// What a recorded actuation was (dry-run hook, see `TrackpadMotor.testRecorder`).
/// pulse: tone-free Gaussian (recorded hz = signed amplitude, ms = width). tone: sine tone(s).
enum MotorKind: String, Sendable { case tone, waveform, impulse, pulse }

/// Return codes of the governor (negative = nothing was sent to the actuator).
enum MotorRC {
    static let throttled: Int32 = -10   // rate / duty / rest window refused the call
    static let stalled: Int32 = -11     // stall guard tripped, haptics are stopped until `resetGovernor()`
    static let invalid: Int32 = -12     // non-finite argument or unknown waveform id
}

/// Hard safety limits. Enforced inside `TrackpadMotor` for EVERY actuation path; nothing above it can bypass them.
enum MotorLimits {
    static let maxGaussian: Float = 48          // |amplitude| x level, Apple's maximum for actuator revision 10
    static let minWidthMS: Float = 2, maxWidthMS: Float = 12
    static let maxToneLevel: Float = 0.8
    static let maxToneMS: Float = 80
    static let minToneHz: Float = 30, maxToneHz: Float = 400, quietToneHz: Float = 100
    static let maxActsPerSecond = 200
    static let maxDuty = 0.60                   // actuating time / any 1 s window
    static let maxRunMS = 2000.0                // continuous high-energy run, then forced rest
    static let taperFromMS = 1500.0             // amplitude eases to 40 % between taperFromMS and maxRunMS
    static let restMS = 300.0
    static let runGapMS = 40.0                  // gap that still counts as one continuous run
    static let highPulseEnergy: Float = 24      // |amp| x level at or above this counts as high energy
    static let highToneLevel: Float = 0.4
    static let stallCallMS = 25.0
    static let stallFailures = 3
    static let stallCooldownS = 10.0            // a stall latch expires after this, up to stallAutoRetries times
    static let stallAutoRetries = 3
    static let stallRetryResetS = 120.0         // a retry budget refills after this long without a stall
}

/// Snapshot of the motor governor (see `TrackpadMotor.governorStatus`).
struct MotorGovernorStatus: Sendable, Equatable {
    var dutyPercent: Double = 0         // actuating time in the last second, percent
    var actsPerSecond: Double = 0       // accepted actuations in the last second
    var throttled = false               // a call was refused within the last 0.5 s
    var stalled = false                 // stall guard tripped: haptics stopped
    var lastCallMS: Double = 0          // duration of the last real actuator call
    var throttleEvents = 0              // total refused calls (rate / duty / rest)
    var clampEvents = 0                 // total calls whose arguments were clamped
    var restEvents = 0                  // forced rests after a 2 s high-energy run
    var maxRunMS: Double = 0            // longest continuous high-energy run so far
    var stallReason = ""
}

/// Central limiter. Not thread-safe: used under `TrackpadMotor`'s lock.
struct MotorGovernor {
    private struct Rec { var t: Double; var ms: Double }
    private var recs: [Rec] = { var a = [Rec](); a.reserveCapacity(256); return a }()
    private var runStart = -1.0, runEnd = -1.0
    private var restUntil = 0.0
    private var consecFails = 0
    private var consecSlow = 0
    private var lastThrottleT = -10.0
    private var stallT = -1.0, retries = 0, lastRetryT = -1000.0
    private var reopenWanted = false
    private(set) var status = MotorGovernorStatus()

    mutating func reset() { self = MotorGovernor() }
    /// Clears only the stall latch (duty records, rest window and run tracking stay).
    mutating func clearStall() {
        status.stalled = false; status.stallReason = ""
        consecFails = 0; consecSlow = 0; stallT = -1
    }
    /// True once after an automatic stall retry: the caller should re-open the actuator handle.
    mutating func takeReopen() -> Bool { let r = reopenWanted; reopenWanted = false; return r }

    private mutating func purge(_ now: Double) {
        var k = 0
        while k < recs.count && recs[k].t + recs[k].ms * 0.001 < now - 1 { k += 1 }
        if k > 0 { recs.removeFirst(k) }
    }
    private func windowMS(_ now: Double) -> Double {
        var s = 0.0
        for r in recs { let a = max(r.t, now - 1), b = min(r.t + r.ms * 0.001, now); if b > a { s += (b - a) * 1000 } }
        return s
    }
    func snapshot(now: Double) -> MotorGovernorStatus {
        var s = status
        var n = 0
        for r in recs where r.t > now - 1 { n += 1 }
        s.dutyPercent = windowMS(now) / 10
        s.actsPerSecond = Double(n)
        s.throttled = now - lastThrottleT < 0.5
        return s
    }
    mutating func noteClamp() { status.clampEvents += 1 }

    /// Decides whether a call may go out. Returns the amplitude/level scale (taper) or nil + the refusal code.
    mutating func admit(now: Double, ms: Double, high: Bool) -> (scale: Float, rc: Int32) {
        if status.stalled {
            if stallT < 0 { stallT = now }
            if now - lastRetryT > MotorLimits.stallRetryResetS { retries = 0 }
            if now - stallT >= MotorLimits.stallCooldownS && retries < MotorLimits.stallAutoRetries {
                retries += 1; lastRetryT = now; reopenWanted = true
                clearStall()
            } else { return (0, MotorRC.stalled) }
        }
        purge(now)
        func refuse() -> (Float, Int32) { status.throttleEvents += 1; lastThrottleT = now; return (0, MotorRC.throttled) }
        if now < restUntil { return refuse() }
        if recs.count >= MotorLimits.maxActsPerSecond { return refuse() }
        if windowMS(now) + ms > MotorLimits.maxDuty * 1000 { return refuse() }
        var scale: Float = 1
        if high {
            if runEnd < 0 || now > runEnd + MotorLimits.runGapMS * 0.001 { runStart = now }   // new run
            let run = (now + ms * 0.001 - runStart) * 1000
            if run > MotorLimits.maxRunMS {
                restUntil = now + MotorLimits.restMS * 0.001; status.restEvents += 1; runStart = -1; runEnd = -1
                return refuse()
            }
            if run > MotorLimits.taperFromMS {
                scale = 1 - 0.6 * Float((run - MotorLimits.taperFromMS) / (MotorLimits.maxRunMS - MotorLimits.taperFromMS))
            }
            status.maxRunMS = max(status.maxRunMS, run)
            runEnd = now + ms * 0.001
        }
        return (scale, 0)
    }
    /// Books an accepted call (a new call cuts the previous one short).
    mutating func commit(now: Double, ms: Double) {
        if var l = recs.last, l.t + l.ms * 0.001 > now { l.ms = max(0, (now - l.t) * 1000); recs[recs.count - 1] = l }
        recs.append(Rec(t: now, ms: ms))
    }
    /// Stall guard: a call over 25 ms, or 3 failures in a row, stops everything.
    mutating func result(rc: Int32, callMS: Double) {
        status.lastCallMS = callMS
        if rc != 0 { consecFails += 1 } else { consecFails = 0 }
        if callMS > MotorLimits.stallCallMS { consecSlow += 1 } else { consecSlow = 0 }
        if consecSlow >= 2 || callMS > MotorLimits.stallCallMS * 4 {   // one preempted call is not a stall
            status.stalled = true; status.stallReason = String(format: "actuator call took %.0f ms", callMS)
        } else if consecFails >= MotorLimits.stallFailures {
            status.stalled = true; status.stallReason = "actuator returned status \(rc) \(consecFails) times"
        }
        if status.stalled { NSLog("HapticGlow: haptics stopped (%@)", status.stallReason) }
    }
}

/// The three primitives the Force Touch actuator offers:
///  - tone       : 1-3 sine tones, 80 Hz-4 kHz, MTActuationCreateFromDictionary + MTActuationActuate
///  - waveform   : built-in system click/buzz/tap shapes, MTActuatorActuate(actuator, id, ...)
///  - impulse    : Gaussian BaseWaveform pulse with no tones (the crispest possible tap)
final class TrackpadMotor: @unchecked Sendable {
    static let shared = TrackpadMotor()

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias IsBuiltInFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
    private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    private typealias ActuatorActuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32
    private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    private let lock = UnfairLock()
    private var handle: UnsafeMutableRawPointer?
    private var createList: CreateList?
    private var getID: GetID?
    private var isBuiltInFn: IsBuiltInFn?
    private var actuatorCreate: ActuatorCreate?
    private var actuatorOpen: ActuatorOpen?
    private var actuatorClose: ActuatorClose?
    private var actuationCreate: ActuationCreate?
    private var actuationPlay: ActuationPlay?
    private var actuatorActuate: ActuatorActuate?

    private var actuator: CFTypeRef?
    private var actuatorPtr: UnsafeMutableRawPointer?
    private var opened = false
    private var openedExternal = false
    private var builtIn = false
    private(set) var deviceID: UInt64 = 0
    private var count: UInt64 = 0
    private var _lastStatus: Int32 = 0

    // Cached, reused dictionary objects (ping-pong so a retained dict is never mutated mid-use).
    private final class Shape {
        let root = NSMutableDictionary()
        let base = NSMutableDictionary()
        let tones = NSMutableArray()
        let toneDicts: [NSMutableDictionary] = (0..<3).map { _ in NSMutableDictionary() }
        init() {
            base["Type"] = "Gaussian"; base["Amplitude"] = NSNumber(value: 0.0)
            root["BaseWaveform"] = base; root["Tones"] = tones
            for d in toneDicts { d["Type"] = "Sine"; d["DelayMS"] = NSNumber(value: 0.0) }
        }
    }
    private let shapes = [Shape(), Shape()]
    private var gov = MotorGovernor()
    /// Quiet mode caps every tone at 100 Hz. Set by the engine from `HapticConfig.quiet` (default on).
    var quietMode: Bool { get { lock.withLock { _quiet } } set { lock.withLock { _quiet = newValue } } }
    private var _quiet = true
    /// Lifts the 400 Hz tone ceiling for the nospeaker-style "Pure Trackpad" (.full) mode only. Default off.
    var allowSpeakerBand: Bool { get { lock.withLock { _speaker } } set { lock.withLock { _speaker = newValue } } }
    private var _speaker = false
    private var shapeIdx = 0
    /// Tone-free Gaussian pulse: BaseWaveform with a signed Amplitude and no tones (ping-pong like `shapes`).
    private final class ImpulseShape {
        let root = NSMutableDictionary(), base = NSMutableDictionary(), tones = NSArray()
        init() { base["Type"] = "Gaussian"; base["Amplitude"] = NSNumber(value: 1.0); root["BaseWaveform"] = base; root["Tones"] = tones }
    }
    private let impulseShapes = [ImpulseShape(), ImpulseShape()]
    private var impulseIdx = 0

    /// Dry-run hook for tests: when set, every play/playSegs/playWaveform/impulse call is reported here
    /// (kind, hz — dominant tone / waveform id / 0 for impulse —, ms, level, time) and NOTHING is actuated.
    /// `testClock` overrides the time stamp (simulated real time). Both are test-only.
    var testRecorder: ((_ kind: MotorKind, _ hz: Float, _ ms: Float, _ level: Float, _ time: Double) -> Void)?
    var testClock: (() -> Double)?
    @inline(__always) private func clockNow() -> Double { testClock?() ?? hostNow() }
    @inline(__always) private func record(_ k: MotorKind, _ hz: Float, _ ms: Float, _ lv: Float) -> Bool {
        guard let r = testRecorder else { return false }
        r(k, hz, ms, lv, clockNow())
        count &+= 1
        return true
    }

    /// Governor state (duty, rate, throttling, stall). Safe to poll from any thread.
    var governorStatus: MotorGovernorStatus { lock.withLock { gov.snapshot(now: clockNow()) } }
    /// Test hook: feeds a fake actuator result to the stall guard (dry-run has no real call to time).
    func testInjectCallResult(rc: Int32, callMS: Double) { lock.withLock { gov.result(rc: rc, callMS: callMS) } }
    /// Clears a stall / rest / counters (explicit user action, e.g. a "restart haptics" button).
    func resetGovernor() { lock.withLock { gov.reset() } }

    /// True when MTActuatorActuate (built-in system waveforms) resolved.
    var hasWaveforms: Bool { lock.withLock { _ = resolve(); return actuatorActuate != nil } }
    /// Symbol audit without actuating anything: name -> resolved.
    func symbolReport() -> [String: Bool] {
        lock.withLock {
            _ = resolve()
            return ["MTDeviceCreateList": createList != nil, "MTActuatorCreateFromDeviceID": actuatorCreate != nil,
                    "MTActuatorOpen": actuatorOpen != nil, "MTActuationCreateFromDictionary": actuationCreate != nil,
                    "MTActuationActuate": actuationPlay != nil, "MTActuatorActuate": actuatorActuate != nil]
        }
    }

    var isAvailable: Bool { lock.withLock { opened } }
    var isBuiltIn: Bool { lock.withLock { builtIn } }
    var actuationCount: UInt64 { lock.withLock { count } }
    var lastStatus: Int32 { lock.withLock { _lastStatus } }

    private func resolve() -> Bool {
        if handle == nil {
            handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
            guard let h = handle else { return false }
            func s<T>(_ n: String, _: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
            createList = s("MTDeviceCreateList", CreateList.self)
            getID = s("MTDeviceGetDeviceID", GetID.self)
            isBuiltInFn = s("MTDeviceIsBuiltIn", IsBuiltInFn.self)
            actuatorCreate = s("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
            actuatorOpen = s("MTActuatorOpen", ActuatorOpen.self)
            actuatorClose = s("MTActuatorClose", ActuatorClose.self)
            actuationCreate = s("MTActuationCreateFromDictionary", ActuationCreate.self)
            actuationPlay = s("MTActuationActuate", ActuationPlay.self)
            actuatorActuate = s("MTActuatorActuate", ActuatorActuate.self)
        }
        return createList != nil && getID != nil && actuatorCreate != nil && actuatorOpen != nil
            && actuationCreate != nil && actuationPlay != nil
    }

    /// Opens the Force Touch actuator (built-in preferred unless preferExternal). Idempotent.
    @discardableResult func open(preferExternal: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return openLocked(preferExternal: preferExternal)
    }
    /// Closes and re-opens the actuator (stale handle after sleep) and clears the stall latch.
    func reopen() {
        lock.lock(); defer { lock.unlock() }
        let was = opened, ext = openedExternal
        closeLocked()
        gov.clearStall()
        if was { _ = openLocked(preferExternal: ext) }
    }
    /// Clears only the stall latch; duty, rest and run limits stay in force.
    func clearStall() { lock.withLock { gov.clearStall() } }
    private func admitLocked(now: Double, ms: Double, high: Bool) -> (scale: Float, rc: Int32) {
        let v = gov.admit(now: now, ms: ms, high: high)
        if gov.takeReopen() { let ext = openedExternal; let was = opened; closeLocked(); if was { _ = openLocked(preferExternal: ext) } }
        return v
    }
    private func openLocked(preferExternal: Bool) -> Bool {
        if opened && openedExternal == preferExternal { return true }
        if opened { closeLocked() }
        guard resolve(), let createList, let getID, let actuatorCreate, let actuatorOpen,
              let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { return false }
        var devs: [(id: UInt64, builtIn: Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(dev, &id) == 0 { devs.append((id, isBuiltInFn?(dev) ?? false)) }
        }
        let ordered = preferExternal ? devs.filter { !$0.builtIn }
                                     : devs.sorted { $0.builtIn && !$1.builtIn }
        for d in ordered {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                actuator = ref
                actuatorPtr = Unmanaged.passUnretained(ref as AnyObject).toOpaque()
                deviceID = d.id; builtIn = d.builtIn
                opened = true; openedExternal = preferExternal
                return true
            }
        }
        return false
    }

    func close() { lock.withLock { closeLocked() } }
    private func closeLocked() {
        if let a = actuator, let actuatorClose { _ = actuatorClose(a) }
        actuator = nil; actuatorPtr = nil; opened = false
    }

    // MARK: - Governed actuation (every path below goes through `MotorGovernor`)

    /// Runs one real actuator call, timing it for the stall guard.
    private func timed(_ body: () -> Int32) -> Int32 {
        let t0 = hostNow()
        let rc = body()
        gov.result(rc: rc, callMS: (hostNow() - t0) * 1000)
        count &+= 1; _lastStatus = rc
        return rc
    }

    /// Tone-free Gaussian pulse (the crisp primitive). `amplitude` is signed: a negative value pushes the
    /// other way, usable as a brake after a positive pulse. Limits: width 2...12 ms, level 0...1,
    /// |amplitude| x level <= 48. Returns the MT status (0 = ok) or a negative `MotorRC` when refused.
    @discardableResult func pulse(amplitude: Float, widthMS: Float, level: Float) -> Int32 {
        guard amplitude.isFinite, widthMS.isFinite, level.isFinite else { return MotorRC.invalid }
        lock.lock(); defer { lock.unlock() }
        let w = min(MotorLimits.maxWidthMS, max(MotorLimits.minWidthMS, widthMS))
        let lv = min(1, max(0, level))
        var a = min(MotorLimits.maxGaussian, max(-MotorLimits.maxGaussian, amplitude))
        if a * lv != 0 && abs(a * lv) > MotorLimits.maxGaussian { a = (a < 0 ? -1 : 1) * MotorLimits.maxGaussian / lv }
        if w != widthMS || lv != level || a != amplitude { gov.noteClamp() }
        let now = clockNow()
        let verdict = admitLocked(now: now, ms: Double(w), high: abs(a * lv) >= MotorLimits.highPulseEnergy)
        if verdict.rc != 0 { return verdict.rc }
        a *= verdict.scale
        if record(.pulse, a, w, lv) { gov.commit(now: now, ms: Double(w)); return 0 }
        guard opened, let actuationCreate, let actuationPlay, let ptr = actuatorPtr else { return -1 }
        let sh = impulseShapes[impulseIdx]; impulseIdx ^= 1
        sh.base["Amplitude"] = NSNumber(value: Double(a))
        sh.base["DurationMS"] = NSNumber(value: Double(w))
        guard let act = actuationCreate(unsafeBitCast(sh.root, to: CFDictionary.self), 0) else { return -2 }
        gov.commit(now: now, ms: Double(w))
        let rc = timed { actuationPlay(act, ptr, 0, lv, 0) }
        Unmanaged<AnyObject>.fromOpaque(act).release()
        return rc
    }

    /// One low sine tone with base amplitude 0 (a pure vibration, no click). Limits: 30...400 Hz (quiet mode
    /// <= 100 Hz), 2...80 ms, level <= 0.8.
    @discardableResult func sine(hz: Float, ms: Float, level: Float) -> Int32 {
        guard hz.isFinite, ms.isFinite, level.isFinite else { return MotorRC.invalid }
        lock.lock(); defer { lock.unlock() }
        return sineLocked(hz: hz, ms: ms, level: level)
    }
    private func sineLocked(hz: Float, ms: Float, level: Float) -> Int32 {
        let f = min(_quiet ? MotorLimits.quietToneHz : MotorLimits.maxToneHz, max(MotorLimits.minToneHz, hz))
        let d = min(MotorLimits.maxToneMS, max(2, ms))
        let lv = min(MotorLimits.maxToneLevel, max(0, level))
        if f != hz || d != ms || lv != level { gov.noteClamp() }
        let now = clockNow()
        let verdict = admitLocked(now: now, ms: Double(d), high: lv >= MotorLimits.highToneLevel)
        if verdict.rc != 0 { return verdict.rc }
        let l2 = lv * verdict.scale
        if record(.tone, f, d, l2) { gov.commit(now: now, ms: Double(d)); return 0 }
        guard opened, let actuationCreate, let actuationPlay, let ptr = actuatorPtr else { return -1 }
        let sh = shapes[shapeIdx]; shapeIdx ^= 1
        sh.tones.removeAllObjects()
        let t = sh.toneDicts[0]
        t["Amplitude"] = NSNumber(value: 1.0); t["DurationMS"] = NSNumber(value: Double(d)); t["FrequencykHz"] = NSNumber(value: Double(f) / 1000)
        sh.tones.add(t)
        sh.base["Amplitude"] = NSNumber(value: 0.0)
        sh.base["DurationMS"] = NSNumber(value: Double(d))
        guard let act = actuationCreate(unsafeBitCast(sh.root, to: CFDictionary.self), 0) else { return -2 }
        gov.commit(now: now, ms: Double(d))
        let rc = timed { actuationPlay(act, ptr, 0, l2, 0) }
        Unmanaged<AnyObject>.fromOpaque(act).release()
        return rc
    }

    /// Apple's built-in waveform via MTActuatorActuate. Only IDs 1-6, 15, 16 are accepted.
    @discardableResult func systemWaveform(id: Int32) -> Int32 {
        guard (1...6).contains(id) || id == 15 || id == 16 else { return MotorRC.invalid }
        lock.lock(); defer { lock.unlock() }
        let now = clockNow()
        let dur: Double = (id == 3 || id == 15 || id == 16) ? 15 : 10
        let verdict = admitLocked(now: now, ms: dur, high: true)
        if verdict.rc != 0 { return verdict.rc }
        if record(.waveform, Float(id), 0, 1) { gov.commit(now: now, ms: dur); return 0 }
        guard opened, let actuatorActuate, let a = actuator else { return -1 }
        gov.commit(now: now, ms: dur)
        return timed { actuatorActuate(a, id, 0, 0, 0) }
    }

    // MARK: - Legacy multi-tone path (nospeaker-style "Pure Trackpad" modes: kick / bass / full)

    /// Plays up to 3 tones together for `ms` ms at `level` (amps normalised to sum 1). Internal: used by the
    /// legacy kick / bass / full modes. Governed like everything else (level <= 0.8, <= 80 ms, 30-400 Hz
    /// unless `allowSpeakerBand`, quiet <= 100 Hz).
    @discardableResult internal func play(_ tones: [MotorTone], ms: Float, level: Float) -> Int32 {
        guard !tones.isEmpty else { return -1 }
        func seg(_ i: Int) -> MotorSeg? { i < tones.count ? MotorSeg(hz: tones[i].hz, amp: tones[i].amp, ms: ms) : nil }
        return playSegs(seg(0)!, seg(1), seg(2), level: level)
    }

    /// Allocation-light legacy path. Each tone carries its own duration.
    @discardableResult internal func playSegs(_ a: MotorSeg, _ b: MotorSeg? = nil, _ c: MotorSeg? = nil, level: Float) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let ceilHz: Float = _quiet ? MotorLimits.quietToneHz : (_speaker ? 4000 : MotorLimits.maxToneHz)
        func fix(_ s: MotorSeg) -> MotorSeg {
            MotorSeg(hz: min(ceilHz, max(MotorLimits.minToneHz, s.hz.isFinite ? s.hz : 60)), amp: s.amp.isFinite ? s.amp : 1,
                     ms: min(MotorLimits.maxToneMS, max(1, s.ms.isFinite ? s.ms : 5)))
        }
        let a = fix(a), b = b.map(fix), c = c.map(fix)
        let lvIn = min(MotorLimits.maxToneLevel, max(0, level.isFinite ? level : 0))
        let maxMS = max(a.ms, b?.ms ?? 0, c?.ms ?? 0)
        let now = clockNow()
        let verdict = admitLocked(now: now, ms: Double(maxMS), high: lvIn >= MotorLimits.highToneLevel)
        if verdict.rc != 0 { return verdict.rc }
        let lv = lvIn * verdict.scale
        if testRecorder != nil {
            var hz = a.hz, best = a.amp
            if let b, b.amp > best { hz = b.hz; best = b.amp }
            if let c, c.amp > best { hz = c.hz }
            _ = record(.tone, hz, maxMS, lv)
            gov.commit(now: now, ms: Double(maxMS))
            return 0
        }
        guard opened, let actuationCreate, let actuationPlay, let ptr = actuatorPtr else { return -1 }
        var segs = (a, b, c)
        let n = c != nil ? 3 : (b != nil ? 2 : 1)
        var sum = max(0.0001, a.amp) + (b.map { max(0.0001, $0.amp) } ?? 0) + (c.map { max(0.0001, $0.amp) } ?? 0)
        if !sum.isFinite || sum <= 0 { sum = 1 }
        let sh = shapes[shapeIdx]; shapeIdx ^= 1
        sh.tones.removeAllObjects()
        withUnsafePointer(to: &segs) { p in
            p.withMemoryRebound(to: MotorSeg.self, capacity: 3) { arr in
                for i in 0..<n {
                    let s = arr[i]
                    let d = sh.toneDicts[i]
                    d["Amplitude"] = NSNumber(value: Double(max(0.0001, s.amp) / sum))
                    d["DurationMS"] = NSNumber(value: Double(s.ms))
                    d["FrequencykHz"] = NSNumber(value: Double(s.hz) / 1000)
                    sh.tones.add(d)
                }
            }
        }
        sh.base["Amplitude"] = NSNumber(value: 0.0)
        sh.base["DurationMS"] = NSNumber(value: Double(maxMS))
        guard let act = actuationCreate(unsafeBitCast(sh.root, to: CFDictionary.self), 0) else { return -2 }
        gov.commit(now: now, ms: Double(maxMS))
        let rc = timed { actuationPlay(act, ptr, 0, lv, 0) }
        Unmanaged<AnyObject>.fromOpaque(act).release()
        return rc
    }

    /// Legacy name for `systemWaveform` (IDs 1-6, 15, 16).
    @discardableResult internal func playWaveform(id: Int32) -> Int32 { systemWaveform(id: id) }

    /// Legacy Gaussian tap: now a 30-amplitude pulse of `ms` at `level` (governed).
    @discardableResult internal func impulse(ms: Float, level: Float) -> Int32 {
        pulse(amplitude: 30, widthMS: ms, level: level)
    }
}
