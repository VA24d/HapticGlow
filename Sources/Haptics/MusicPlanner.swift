// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow - music-mode planner (Apple Music Haptics-style layering on the Force Touch trackpad).
//
// Pure logic, no motor access: `tick` is called by HapticEngine's realtime loop (and by the offline
// test harness in simulated time) and returns at most ONE motor action per call.
//
// Layers, in priority order (kick > snare > hat > texture > melody):
// Core Haptics concepts mapped to the motor primitives (TrackpadMotor.pulse / .sine / .systemWaveform):
//   TRANSIENT kick  -> round + weighty: wide Gaussian pulse (8-12 ms) then a 45-80 Hz sine "body" whose
//                      length follows the kick's decay (808 sustain)          [deeper thump]
//             snare -> crisp: Gaussian pulse 4-6 ms, amp 22-40
//             hat   -> tiny tick: Gaussian pulse 3 ms, amp 8-15, only at high detail
//   CONTINUOUS texture -> bass envelope as a Gaussian pulse train (30-60 Hz, deep/crisp) or 40-70 ms sine
//                      bursts (punchy), pitch folded from the bass, fast attack, slower release, ducked
//                      to 40 % around each tap, faded in dense passages, self-limited to the duty budget
//   REFINED   melody/vocal emphasis as a very light pulse train, sparse passages and high detail only
// Apple rules: sparse and contrasting, >= 70 ms between distinct taps (ghost effect), priority
// kick > snare > hat > texture > melody, one layer leads in dense passages.
//
// SYNC. The capture tap sees audio before the listener hears it (Bluetooth ~ 195 ms). Every music
// event is therefore scheduled at   due = captureTime + SyncClock.delay - motorLatency   and fired
// from a small pending list, i.e. at the true transient time, not at detection time. The analyzer's
// lookahead lets a hit be confirmed (merged, de-duplicated, strength known) before it is due.
// A hit that is more than `lateTolerance` past due is dropped instead of played late. Features for the
// continuous layers are read from a FeatureDelayLine with the same delay.
import Foundation

// MARK: - Tuning (every constant is here; tune after the hands-on feel test)

enum HapticTuning {
    // ---- sync
    /// Seconds between our motor call and the glass actually moving (MTActuationActuate enqueue + actuator ramp).
    static let motorLatency = 0.004
    /// A hit later than due + this is dropped. Never fire later than due + 15 ms.
    static let lateTolerance = 0.015
    /// With a short audio-to-ear delay (built-in speakers) the analyzer's own publish lag is the whole budget:
    /// below `shortDelay` the tolerance widens to `lateToleranceShort` so hits are fired ASAP instead of dropped.
    static let shortDelay = 0.040
    static let lateToleranceShort = 0.050
    /// Continuous layers read analysis frames this much later than the plain delay (the 2048-sample FFT window
    /// is centred ~20 ms before the frame time).
    static let featureLead = 0.010

    // ---- hit gating
    /// Minimum gap between two kick voices (also merges close detections while still pending).
    static var kickMinGap = 0.085
    static let snareMinGap = 0.06
    static let hatMinGap = 0.04
    /// 808 / sub-bass guard: a kick closer than `kickDecayWindow` after the previous one must be at least this
    /// fraction as strong as it, otherwise it is the previous note's tail re-detected and is dropped.
    static var kickDecayWindow = 0.20
    static var kickDecayRatio: Float = 0.55
    /// Taps that are masked by a kick (hats within this time of a kick) are dropped.
    static let hatMaskAfterKick = 0.030

    // ---- quiet mode ceiling
    /// In quiet mode no tone may exceed this frequency (the glass radiates mostly 100 Hz - 4 kHz).
    static let quietMaxHz: Float = 90
    /// Lowest tone the planner will ask for. The actuator API accepts any value; whether the glass moves
    /// below ~60 Hz is a hardware question for the feel test (raise this if "deep" feels like nothing).
    static let motorMinHz: Float = 40

    // ---- kick voices: pitch drops f0 -> f1 with time constant pitchTau, level follows an asymmetric
    // raised-cosine (quick rise over `attack` of the length, smooth fall), sampled per segment.
    // Segments are whole cycles so each one starts and ends at a zero crossing.
    // segMs: minimum segment length; the cycle count is rounded so segments are >= segMs (0 = single cycles).
    // gain: multiplies strength * hit amplitude.
    static let deepQuiet    = HapticVoiceShape(f0: 80, f1: 60, pitchTau: 0.025, len: 0.045, attack: 0.25, segMs: 0, gain: 1.0)
    static let punchyQuiet  = HapticVoiceShape(f0: 90, f1: 62, pitchTau: 0.015, len: 0.030, attack: 0.20, segMs: 0, gain: 1.0)
    static let crispQuiet   = HapticVoiceShape(f0: 90, f1: 78, pitchTau: 0.010, len: 0.022, attack: 0.15, segMs: 0, gain: 1.0)
    static let deepLoud     = HapticVoiceShape(f0: 110, f1: 62, pitchTau: 0.025, len: 0.060, attack: 0.25, segMs: 0, gain: 1.0)
    static let punchyLoud   = HapticVoiceShape(f0: 160, f1: 90, pitchTau: 0.018, len: 0.040, attack: 0.20, segMs: 0, gain: 1.0)
    /// crisp+loud: the original nospeaker chirp (900 -> 120 Hz) with ~5 ms segments.
    static let crispLoud    = HapticVoiceShape(f0: 800, f1: 130, pitchTau: 0.020, len: 0.100, attack: 0.04, segMs: 5, gain: 1.0)

    static func kick(_ feel: HapticFeel, quiet: Bool) -> HapticVoiceShape {
        switch (feel, quiet) {
        case (.deep, true): return deepQuiet
        case (.punchy, true): return punchyQuiet
        case (.crisp, true): return crispQuiet
        case (.deep, false): return deepLoud
        case (.punchy, false): return punchyLoud
        case (.crisp, false): return crispLoud
        }
    }
    /// Pitch/level scaling from the user's `pitch` and `punch` sliders (0...1, 0.5 = shape as written).
    static let pitchSliderRange: Float = 0.25      // +-25 % on f0/f1
    static let punchSliderRange = 0.5              // +-50 % on length

    // ---- snare (soft low tap in quiet mode)
    static let snareQuiet = HapticVoiceShape(f0: 88, f1: 80, pitchTau: 0.01, len: 0.012, attack: 0.3, segMs: 0, gain: 0.55)
    static let snareLoud  = HapticVoiceShape(f0: 130, f1: 100, pitchTau: 0.01, len: 0.016, attack: 0.3, segMs: 0, gain: 0.8)
    /// Hits at or above this strength use a Gaussian impulse for the crisp feel in loud mode only.
    static let snareImpulseStrength: Float = 0.6

    // ---- hard kick click (crisp + loud only)
    static let hardKickStrength: Float = 0.8
    static let hardKickPunch: Float = 0.6

    // ---- texture
    /// Quiet texture folds the bass pitch into this range (octave folding).
    static let textureQuietLo: Float = 40, textureQuietHi: Float = 80
    static let textureLoudLo: Float = 110, textureLoudHi: Float = 450
    /// Quiet texture level ceiling (relative) and slew limits in level units per second.
    static let textureQuietMax: Float = 0.6
    static let textureSlewUp: Float = 14, textureSlewDown: Float = 24
    /// Texture is ducked to this fraction for `duckHold` s after any tap, then recovers over `duckRecover`.
    static let duckFloor: Float = 0.4, duckHold = 0.06, duckRecover = 0.03
    /// Texture segment target length (cycle aligned).
    static let textureSegSec = 0.012, textureSegMax = 0.024

    // ---- planner rate limiter (motor calls block ~3.7 ms each)
    static let rateCap = 200.0, burst: Float = 16, reserve: Float = 4
}

/// Shape of one hit voice. See `HapticTuning`.
struct HapticVoiceShape: Sendable {
    var f0: Float, f1: Float          // pitch start / end (Hz)
    var pitchTau: Double              // pitch-drop time constant (s)
    var len: Double                   // total length (s), segments are added until this is reached
    var attack: Double                // fraction of `len` spent rising
    var segMs: Double                 // minimum segment length in ms (0 = one cycle per segment)
    var gain: Float                   // level multiplier
}

/// One tone segment of a voice, scheduled relative to the voice start.
struct HapticVoiceSeg: Sendable { var start: Double; var hz: Float; var ms: Float; var level: Float }

/// A pre-rendered multi-segment hit (thump / tap). Allocation-free after init.
struct HapticVoice: Sendable {
    private(set) var segs: [HapticVoiceSeg] = { var a = [HapticVoiceSeg](); a.reserveCapacity(24); return a }()
    private var idx = 0
    private(set) var t0 = 0.0
    private(set) var active = false

    /// Renders `shape` for a hit of amplitude `amp` (0...1) at overall `strength`, starting at `at` (due time).
    /// `quiet` clamps every tone to HapticTuning.quietMaxHz. `pitchScale` / `lenScale` come from the sliders.
    mutating func start(_ shape: HapticVoiceShape, amp: Float, strength: Float, at: Double, quiet: Bool,
                        pitchScale: Float = 1, lenScale: Double = 1) {
        segs.removeAll(keepingCapacity: true)
        let hiCap = quiet ? HapticTuning.quietMaxHz : 4000
        let f0 = min(hiCap, max(HapticTuning.motorMinHz, shape.f0 * pitchScale))
        let f1 = min(f0, max(HapticTuning.motorMinHz, shape.f1 * pitchScale))
        let len = max(0.008, shape.len * lenScale)
        // walk the pitch curve to lay out segments
        var t = 0.0
        var raw: [(Double, Float, Double)] = []   // (start, hz, dur)
        raw.reserveCapacity(24)
        while t < len && raw.count < 24 {
            let hz = f1 + (f0 - f1) * Float(exp(-t / shape.pitchTau))
            let cyc = max(1.0, (shape.segMs * 0.001 * Double(hz)).rounded())
            let dur = cyc / Double(hz)
            raw.append((t, hz, dur))
            t += dur
        }
        let total = max(t, 1e-3)
        let a = max(0.02, min(0.9, shape.attack))
        // envelope sampled at each segment centre, then normalised so the loudest segment hits strength * amp * gain
        var envs: [Double] = []
        envs.reserveCapacity(raw.count)
        for (s, _, dur) in raw {
            let x = (s + 0.5 * dur) / total
            if x < a { let u = sin(0.5 * Double.pi * x / a); envs.append(u * u) }
            else { let u = cos(0.5 * Double.pi * (x - a) / (1 - a)); envs.append(u * u) }
        }
        let peak = max(1e-6, envs.max() ?? 1)
        for (k, r) in raw.enumerated() {
            let lv = max(0, min(1, strength * amp * shape.gain * Float(envs[k] / peak)))
            segs.append(HapticVoiceSeg(start: r.0, hz: r.1, ms: Float(r.2 * 1000), level: lv))
        }
        idx = 0; t0 = at; active = true
    }

    /// Next segment that is due at `now`, or nil. Segments that were missed entirely are skipped.
    mutating func next(now: Double) -> HapticVoiceSeg? {
        while idx < segs.count, t0 + segs[idx].start + Double(segs[idx].ms) * 0.001 <= now { idx += 1 }
        guard idx < segs.count else { active = false; return nil }
        let s = segs[idx]
        if t0 + s.start <= now { idx += 1; if idx >= segs.count { active = false }; return s }
        return nil
    }
    mutating func cancel() { active = false; idx = segs.count }
}

/// One transient handed from the analyzer thread to the scheduler.
struct MusicEvent: Sendable {
    var kind: UInt8        // 0 kick, 1 snare, 2 hat
    var strength: Float    // 0...1
    var time: Double       // hostNow() estimate of the actual transient (capture time)
}

/// A motor action: exactly one call on TrackpadMotor.
enum MotorAct: Sendable {
    case tones(MotorSeg, MotorSeg?, Float)   // legacy multi-tone path (kick / bass / full modes)
    case waveform(Int32)                     // built-in system waveform id
    case impulse(Float, Float)               // legacy Gaussian impulse (ms, level)
    case pulse(Float, Float, Float)          // tone-free Gaussian: signed amplitude, width ms, level
    case sine(Float, Float, Float)           // single low sine: hz, ms, level
}

enum MusicLayer: Int, Sendable { case kick, kickWave, snare, hat, texture, melody }

/// Apple-style renderer tuning (music mode).
enum MusicStyle {
    /// Upward compression of onset strength: gentle (ratio 3 above the knee), makeup gain so 1 stays 1.
    static let knee: Float = 0.45, ratio: Float = 3
    static func intensity(_ x: Float) -> Float {
        let v = max(0, min(1, x))
        let y = v <= knee ? v : knee + (v - knee) / ratio
        return min(1, y / (knee + (1 - knee) / ratio))
    }
    /// Pulse amplitude windows (Gaussian units; the motor caps |amp| x level at 48).
    static let kickAmp: ClosedRange<Float> = 16...48
    static let snareAmp: ClosedRange<Float> = 22...40
    static let hatAmp: ClosedRange<Float> = 8...15
    static let textureAmpMax: Float = 34, melodyAmpMax: Float = 14
    /// Spacing between distinct taps (ghost effect) and the sync step between a kick pulse and its body.
    static let tapSpacing = 0.070
    static let rollMax = 6, rollStrong: Float = 0.85
    static let bodyDelay = 0.0045
    /// Texture self-budget: the planner stops texture when all of its actuations in the last second
    /// would exceed this (the motor's own limit is 60 %, so taps keep headroom).
    static let dutyBudgetMS = 520.0, dutyCeilingMS = 570.0
    static let textureDutyPulse = 0.40, textureDutyBurst = 0.45
    /// Texture rest after this long a continuous run (the motor forces one at 2 s; this one is gentler).
    static let textureRunMax = 1.7, textureRest = 0.35, textureTaperFrom = 0.5
    static let denseFrom: Float = 3.5, denseSpan: Float = 3      // taps/s
    static let duckFloor: Float = 0.4, duckBefore = 0.030, duckAfter = 0.080, duckRecover = 0.030

    struct Feel {
        var kickWidth: Float, bodyHz: Float, bodyMS: Float
        var snareWidth: Float, hatWidth: Float
        var burst: Bool                 // texture as sine bursts instead of a pulse train
        var texWidthMax: Float          // pulse train width ceiling
    }
    static func feel(_ f: HapticFeel) -> Feel {
        switch f {
        case .deep:   return Feel(kickWidth: 12, bodyHz: 50, bodyMS: 60, snareWidth: 6, hatWidth: 4, burst: false, texWidthMax: 12)
        case .punchy: return Feel(kickWidth: 10, bodyHz: 58, bodyMS: 45, snareWidth: 5, hatWidth: 3, burst: true, texWidthMax: 9)
        case .crisp:  return Feel(kickWidth: 8, bodyHz: 68, bodyMS: 30, snareWidth: 4, hatWidth: 3, burst: false, texWidthMax: 7)
        }
    }
}

/// Turns AudioFeatures frames into MusicEvents (counter diffing). Used by the engine and the harness.
struct MusicEventFeed {
    var kickN: UInt64 = 0, snareN: UInt64 = 0, hatN: UInt64 = 0
    var primed = false
    mutating func ingest(_ f: AudioFeatures, into out: inout [MusicEvent]) {
        if !primed { kickN = f.onsetCount; snareN = f.snareCount; hatN = f.hatCount; primed = true; return }
        if f.onsetCount != kickN {
            kickN = f.onsetCount
            if out.count < 24 { out.append(MusicEvent(kind: 0, strength: f.onsetStrength, time: f.lastOnsetTime > 0 ? f.lastOnsetTime : f.time)) }
        }
        if f.snareCount != snareN {
            snareN = f.snareCount
            if out.count < 24 { out.append(MusicEvent(kind: 1, strength: f.snareOnset, time: f.lastSnareTime > 0 ? f.lastSnareTime : f.time)) }
        }
        if f.hatCount != hatN {
            hatN = f.hatCount
            if out.count < 24 { out.append(MusicEvent(kind: 2, strength: f.hatOnset, time: f.lastHatTime > 0 ? f.lastHatTime : f.time)) }
        }
    }
}

/// Ring of recent analysis frames so continuous layers (texture, melody, bass mode) can be read `delay`
/// seconds in the past. Not thread-safe: callers hold their own lock.
struct FeatureDelayLine {
    private var buf: [AudioFeatures]
    private var head = 0, count = 0
    init(capacity: Int = 512) { buf = [AudioFeatures](repeating: AudioFeatures(), count: capacity) }
    mutating func push(_ f: AudioFeatures) { buf[head] = f; head = (head + 1) % buf.count; count = min(count + 1, buf.count) }
    mutating func clear() { head = 0; count = 0 }
    /// Newest frame whose time is <= t; the oldest frame if t precedes all; `fallback` if empty.
    func at(_ t: Double, fallback: AudioFeatures) -> AudioFeatures {
        guard count > 0 else { return fallback }
        var i = 0
        while i < count {
            let f = buf[(head - 1 - i + buf.count * 2) % buf.count]
            if f.time <= t || i == count - 1 { return f }
            i += 1
        }
        return fallback
    }
}

final class MusicPlanner {
    // stats (read by the harness / UI)
    /// Taps and texture per layer: kick, kickWave, snare, hat, texture, melody (kick counts the pulse only).
    private(set) var counts = [UInt64](repeating: 0, count: 6)
    private(set) var bodyCount: UInt64 = 0
    /// Nominal actuating milliseconds per layer (same order as `counts`).
    private(set) var layerMS = [Double](repeating: 0, count: 6)
    private(set) var masked: UInt64 = 0, dropped: UInt64 = 0, retriggerBlocked: UInt64 = 0, rateBlocked: UInt64 = 0
    private(set) var lastLayer: MusicLayer = .texture
    private(set) var lastLevel: Float = 0
    var impulseOK = true            // legacy, kept for the engine
    var hasWaveforms = true         // cleared by the engine if MTActuatorActuate did not resolve

    static var motorLatency: Double { HapticTuning.motorLatency }
    static var rateCap: Double { HapticTuning.rateCap }

    /// Audio-to-ear delay the planner schedules against (SyncClock; override for tests).
    var delayOverride: Double?
    func syncDelay() -> Double { delayOverride ?? SyncClock.shared.delay }
    /// Capture-clock time of the audio that is being heard at `now` (+ the actuation latency): where the
    /// continuous layers should sample their features.
    func featureTime(now: Double) -> Double { now - syncDelay() + HapticTuning.motorLatency + HapticTuning.featureLead }

    // pending hits (fixed capacity). `due` is when the first motor call should be issued.
    private struct Pending { var e: MusicEvent; var due: Double }
    private var pend: [Pending] = { var a = [Pending](); a.reserveCapacity(64); return a }()
    private struct Step { var at: Double; var act: MotorAct; var layer: MusicLayer; var lvl: Float; var ms: Double }
    private var steps: [Step] = { var a = [Step](); a.reserveCapacity(4); return a }()
    private var lastTick = 0.0
    private var lastKickT = -1.0, lastKickStr: Float = 0, lastSnareT = -1.0, lastHatT = -1.0
    private var lastTapAt = -1.0
    private var tapRate: Float = 0   // decayed taps/s (kick+snare 1, hat 0.4)
    private var duckUntil = 0.0
    private var busyUntil = 0.0
    private var kickFires: [Double] = { var a = [Double](); a.reserveCapacity(16); return a }()

    // own actuation log for the duty budget: (time, ms)
    private var actLog: [(t: Double, ms: Double)] = { var a = [(t: Double, ms: Double)](); a.reserveCapacity(256); return a }()

    // raw analysis history (capture time) so a kick's decay can be read ahead of its due time
    private var histT = [Double](repeating: 0, count: 320), histV = [Float](repeating: 0, count: 320)
    private var histHead = 0, histN = 0, lastObs = -1.0

    // texture voice
    private var env: Float = 0, log2Hz: Float = 0, have = false, texDue = 0.0
    private var texStart = 0.0, texLastDrive = 0.0, texRestUntil = 0.0
    // melody voice
    private var melDue = 0.0, melLog2: Float = 0, melHave = false

    func reset() {
        pend.removeAll(keepingCapacity: true); steps.removeAll(keepingCapacity: true); actLog.removeAll(keepingCapacity: true)
        tapRate = 0; env = 0; have = false; texDue = 0; melDue = 0; duckUntil = 0; texStart = 0; texLastDrive = 0; texRestUntil = 0
        busyUntil = 0; melHave = false; kickFires.removeAll(keepingCapacity: true); histHead = 0; histN = 0; lastObs = -1
        lastKickT = -1; lastKickStr = 0; lastSnareT = -1; lastHatT = -1; lastTapAt = -1
    }
    func resetStats() {
        for i in 0..<6 { counts[i] = 0; layerMS[i] = 0 }
        bodyCount = 0; masked = 0; dropped = 0; retriggerBlocked = 0; rateBlocked = 0
    }

    @inline(__always) private func c01(_ x: Float) -> Float { max(0, min(1, x)) }

    /// Debug: true while a kick voice still has queued steps.
    var kickActive: Bool { !steps.isEmpty }
    /// True when no hits are queued and the continuous texture envelope has settled.
    var isIdle: Bool { pend.isEmpty && steps.isEmpty && env < 0.005 && tapRate < 0.01 }

    /// Folds `hz` by octaves into [lo, hi) (hi/lo >= 2).
    static func fold(_ hz: Float, lo: Float, hi: Float) -> Float {
        var f = max(1, hz)
        while f < lo { f *= 2 }
        while f >= hi { f *= 0.5 }
        return f
    }

    private func lateLimit(_ delay: Double) -> Double {
        delay < HapticTuning.shortDelay ? HapticTuning.lateToleranceShort : HapticTuning.lateTolerance
    }

    /// Feed every raw (undelayed) analysis frame in order. Used to measure how long a kick rings.
    func observe(_ f: AudioFeatures) {
        guard f.time > lastObs else { return }
        lastObs = f.time
        histT[histHead] = f.time; histV[histHead] = f.belowCutoff
        histHead = (histHead + 1) % histT.count; histN = min(histN + 1, histT.count)
    }

    /// 0...1 how much of a kick's low-band energy is still there 60-140 ms after the hit (808 sustain).
    /// Returns 0.25 when the analysis has not reached that far yet (short audio delay).
    private func sustain(at te: Double) -> Float {
        var peak: Float = 0, tail: Float = 0, nt = 0
        var latest = te
        for k in 0..<histN {
            let i = (histHead - 1 - k + histT.count * 2) % histT.count
            let t = histT[i]
            if t > latest { latest = t }
            if t < te - 0.02 { break }
            let dt = t - te
            if dt >= -0.01 && dt <= 0.04 { peak = max(peak, histV[i]) }
            if dt >= 0.06 && dt <= 0.14 { tail += histV[i]; nt += 1 }
        }
        guard nt >= 3, peak > 0.05 else { return 0.25 }
        return c01((tail / Float(nt)) / peak)
    }

    // MARK: duty bookkeeping

    private func dutyMS(_ now: Double) -> Double {
        var s = 0.0
        var k = 0
        for r in actLog { if r.t + r.ms * 0.001 < now - 1 { k += 1 } else { break } }
        if k > 0 { actLog.removeFirst(k) }
        for r in actLog { let a = max(r.t, now - 1), b = min(r.t + r.ms * 0.001, now); if b > a { s += (b - a) * 1000 } }
        return s
    }
    private func book(_ now: Double, _ ms: Double, _ layer: MusicLayer, _ lvl: Float) {
        if let l = actLog.last, l.t + l.ms * 0.001 > now { actLog[actLog.count - 1].ms = max(0, (now - l.t) * 1000) }
        actLog.append((now, ms))
        layerMS[layer.rawValue] += ms
        lastLayer = layer; lastLevel = lvl
        busyUntil = now + ms * 0.001
    }

    private func fire(_ s: Step, now: Double) -> MotorAct {
        book(now, s.ms, s.layer, s.lvl)
        switch s.act { case .sine: bodyCount += 1; if s.layer != .kick { counts[s.layer.rawValue] += 1 }
                       default: counts[s.layer.rawValue] += 1 }
        return s.act
    }

    // MARK: tick

    /// One scheduler step. `f` must already be the delayed feature frame (see `featureTime`). `events` are new
    /// transients since the last call (oldest first), in capture time.
    func tick(now: Double, f: AudioFeatures, events: [MusicEvent], cfg c: HapticConfig) -> MotorAct? {
        let strength = c01(c.strength), detail = c01(c.detail), tex = c01(c.texture)
        let quiet = c.quiet
        let feel = MusicStyle.feel(c.feel)
        let dt = lastTick > 0 ? max(0, min(0.05, now - lastTick)) : 0
        lastTick = now
        if f.silent && events.isEmpty && pend.isEmpty && steps.isEmpty && env < 0.005 {
            env = 0
            tapRate = tapRate < 0.01 ? 0 : tapRate * expf(-Float(dt) / 1.5)
            have = false; melHave = false; texStart = 0
            if !actLog.isEmpty { _ = dutyMS(now) }
            return nil
        }
        tapRate *= expf(-Float(dt) / 1.5)
        let delay = syncDelay()
        let late = lateLimit(delay)
        if strength < 0.02 { return nil }   // strength 0 silences the taps
        let lvl = strength                  // pulse level argument; amplitude carries the dynamics

        // ---- ingest: schedule at capture time + delay - motor latency; merge/dedupe while still pending
        for e in events {
            let due = e.time + delay - HapticTuning.motorLatency
            switch e.kind {
            case 0:
                if let j = pend.firstIndex(where: { $0.e.kind == 0 && abs($0.e.time - e.time) < HapticTuning.kickMinGap }) {
                    if e.strength > pend[j].e.strength { pend[j].e.strength = e.strength }
                    if e.time < pend[j].e.time { pend[j].e.time = e.time; pend[j].due = due }
                    retriggerBlocked += 1; continue
                }
                if e.time - lastKickT < HapticTuning.kickMinGap { retriggerBlocked += 1; continue }
                // an 808 tail re-detected: much weaker than the note it follows
                if e.time - lastKickT < HapticTuning.kickDecayWindow && e.strength < HapticTuning.kickDecayRatio * lastKickStr {
                    retriggerBlocked += 1; continue
                }
                lastKickT = e.time; lastKickStr = e.strength
            case 1:
                if detail < 0.12 || e.time - lastSnareT < HapticTuning.snareMinGap { continue }
                lastSnareT = e.time
            default:
                if detail < 0.6 || e.time - lastHatT < HapticTuning.hatMinGap { continue }
                lastHatT = e.time
            }
            if pend.count < 64 { pend.append(Pending(e: e, due: due)) }
        }
        // ---- drop hits that are too late (never play one more than `late` past due)
        var i = 0
        while i < pend.count {
            if now - pend[i].due > late { pend.swapAt(i, pend.count - 1); pend.removeLast(); dropped += 1 } else { i += 1 }
        }
        // ---- texture envelope (runs every tick so smoothing is time-correct)
        let raw = c01(f.belowCutoff)
        let tc: Float = raw > env ? 0.003 : (0.08 - 0.06 * c01(c.punch))
        env += (raw - env) * (1 - expf(-Float(max(0.001, dt)) / tc))
        let envEff = env * c01((max(f.sub, f.bass) - 0.25) / 0.3)
        let dense = c01((tapRate - MusicStyle.denseFrom) / MusicStyle.denseSpan)

        // ---- 1. kick: the earliest due kick (a kick always preempts)
        var kickIdx = -1
        for (j, p) in pend.enumerated() where p.e.kind == 0 && now >= p.due { kickIdx = j; break }
        if kickIdx >= 0 {
            let p = pend[kickIdx]
            pend.remove(at: kickIdx)
            let I = MusicStyle.intensity(p.e.strength)
            // 808 rolls: more than `rollMax` kick taps in the last second only let strong ones through (Apple: sparse)
            kickFires.removeAll { now - $0 > 1 }
            if kickFires.count >= MusicStyle.rollMax && I < MusicStyle.rollStrong { masked += 1; return nil }
            kickFires.append(now)
            let pu = c01(c.punch), pt = c01(c.pitch)
            let sus = sustain(at: p.e.time)
            steps.removeAll(keepingCapacity: true)
            duckUntil = now + MusicStyle.duckAfter; lastTapAt = now; tapRate += 1 / 1.5
            let hard = !quiet && c.feel == .crisp && hasWaveforms && I > 0.9 && pu > 0.6
            if hard {
                counts[MusicLayer.kickWave.rawValue] += 1
                book(now, 10, .kickWave, I)
                return .waveform(6)
            }
            // body: whole cycles of a 45-80 Hz sine (quiet) whose length follows the decay of the kick
            let hzScale = 1 + 0.25 * (pt - 0.5) * 2
            let hzMax: Float = quiet ? 80 : 100
            let hz = min(hzMax, max(45, feel.bodyHz * hzScale * (quiet ? 1 : 1.1)))
            // a busy second shortens the body so taps stay inside the duty budget
            let busy = Float(max(0, min(1, (dutyMS(now) - 300) / 250)))
            var bodyMS = feel.bodyMS * (1 + 0.4 * (pu - 0.5) * 2) * (1 + 1.2 * sus) * (1 - 0.5 * busy)
            bodyMS = min(140, max(24, bodyMS))
            // never ask for more than the duty window can take (the motor refuses at 60 %)
            let w = min(12, max(8, feel.kickWidth - 4 * (pu - 0.5)))
            bodyMS = min(bodyMS, Float(MusicStyle.dutyCeilingMS - dutyMS(now)) - w)
            let first = min(MotorLimits.maxToneMS, bodyMS)
            let cyc1 = max(1, (first * hz / 1000).rounded(.down))
            let ms1 = cyc1 / hz * 1000
            let bl = min(MotorLimits.maxToneLevel, 0.8 * (0.45 + 0.55 * I) * (0.5 + 0.5 * strength))
            if bodyMS >= 20 { steps.append(Step(at: p.due + MusicStyle.bodyDelay, act: .sine(hz, ms1, bl), layer: .kick, lvl: bl / 0.8, ms: Double(ms1))) }
            if bodyMS > MotorLimits.maxToneMS + 8 {
                let cyc2 = max(1, min(((MotorLimits.maxToneMS * hz / 1000).rounded(.down)), ((bodyMS - ms1) * hz / 1000).rounded()))
                let ms2 = cyc2 / hz * 1000
                steps.append(Step(at: p.due + MusicStyle.bodyDelay + Double(ms1) * 0.001, act: .sine(hz, ms2, bl * 0.6), layer: .kick, lvl: bl * 0.6 / 0.8, ms: Double(ms2)))
            }
            let amp = MusicStyle.kickAmp.lowerBound + (MusicStyle.kickAmp.upperBound - MusicStyle.kickAmp.lowerBound) * I
            book(now, Double(w), .kick, I)
            counts[MusicLayer.kick.rawValue] += 1
            return .pulse(amp, w, lvl)
        }
        // ---- 2. queued follow-up steps (kick body)
        if let s = steps.first, now >= s.at {
            steps.removeFirst()
            if now - s.at <= 0.03 { return fire(s, now: now) }
        }
        // ---- 3. snare / hat: lowest kind first, spacing + priority arbitration against what is still ahead
        var tapIdx = -1
        for (j, p) in pend.enumerated() where p.e.kind != 0 && now >= p.due { if tapIdx < 0 || p.e.kind < pend[tapIdx].e.kind { tapIdx = j } }
        if tapIdx >= 0 {
            let p = pend[tapIdx]
            pend.remove(at: tapIdx)
            let e = p.e
            var drop = now - lastTapAt < MusicStyle.tapSpacing || !steps.isEmpty
            if !drop { drop = pend.contains { $0.e.kind < e.kind && abs($0.due - p.due) < MusicStyle.tapSpacing } }
            if e.kind == 2 && tapRate > 4.5 { drop = true }          // dense: hats thin out, the kick/snare lead
            if drop { masked += 1 }
            else {
                lastTapAt = now; tapRate += (e.kind == 1 ? 1 : 0.4) / 1.5
                duckUntil = now + MusicStyle.duckAfter
                let I = MusicStyle.intensity(e.strength)
                if e.kind == 1 {
                    let dFac = 0.55 + 0.45 * c01(detail * 1.6)
                    if !quiet && c.feel == .crisp && hasWaveforms && I > 0.85 {
                        counts[MusicLayer.snare.rawValue] += 1; book(now, 10, .snare, I)
                        return .waveform(2)
                    }
                    let amp = (MusicStyle.snareAmp.lowerBound + (MusicStyle.snareAmp.upperBound - MusicStyle.snareAmp.lowerBound) * I) * dFac
                    let w = quiet ? max(6, feel.snareWidth) : feel.snareWidth
                    counts[MusicLayer.snare.rawValue] += 1; book(now, Double(w), .snare, I * dFac)
                    return .pulse(amp, w, lvl)
                } else {
                    let amp = (MusicStyle.hatAmp.lowerBound + (MusicStyle.hatAmp.upperBound - MusicStyle.hatAmp.lowerBound) * I) * (0.6 + 0.4 * detail)
                    let w = quiet ? max(6, feel.hatWidth + 2) : feel.hatWidth
                    counts[MusicLayer.hat.rawValue] += 1; book(now, Double(w), .hat, I * 0.4)
                    return .pulse(amp, w, lvl)
                }
            }
        }
        // ---- 4. continuous layers wait for the motor and for any tap that is about to land
        if now < busyUntil || !steps.isEmpty { return nil }
        let tapSoon = pend.contains { $0.e.kind != 2 && $0.due - now < 0.012 && $0.due - now > -0.001 }
        if tapSoon { return nil }

        // texture
        let hot = !f.silent && envEff > 0.02 && tex > 0.01
        if !hot { if now - texLastDrive > 0.05 { texStart = 0 } }
        if hot && now >= texDue && now >= texRestUntil {
            let lo: Float = quiet ? 30 : 30, hi: Float = 60
            var tgt: Float = have ? log2Hz : log2f(45)
            if f.bassPitchHz > 20 {
                tgt = log2f(Self.fold(f.bassPitchHz, lo: feel.burst ? 40 : lo, hi: feel.burst ? 80 : hi))
            }
            if !have { log2Hz = tgt; have = true } else {
                let maxStep: Float = 0.5 * Float(max(dt, 0.001)) / 0.010
                log2Hz += max(-maxStep, min(maxStep, (tgt - log2Hz) * 0.3))
            }
            let hz = exp2f(log2Hz)
            // sidechain duck around each tap (also just before the next one), then a short recovery ramp
            var duck: Float = 1
            if now < duckUntil { duck = MusicStyle.duckFloor }
            else if now < duckUntil + MusicStyle.duckRecover {
                duck = MusicStyle.duckFloor + (1 - MusicStyle.duckFloor) * Float((now - duckUntil) / MusicStyle.duckRecover)
            }
            if pend.contains(where: { $0.e.kind != 2 && $0.due - now < MusicStyle.duckBefore && $0.due > now }) { duck = MusicStyle.duckFloor }
            // run taper: a held note eases down, then rests (the motor would force a rest at 2 s)
            if texStart == 0 || now - texLastDrive > 0.05 { texStart = now }
            let held = now - texStart
            if held > MusicStyle.textureRunMax { texRestUntil = now + MusicStyle.textureRest; texStart = 0; return nil }
            let cap = 1 - 0.45 * Float(max(0, min(1, (held - MusicStyle.textureTaperFrom) / (MusicStyle.textureRunMax - MusicStyle.textureTaperFrom))))
            let y = powf(envEff, 0.6)
            let gain = min(1, tex * 1.3 + 0.05) * y * duck * cap * (1 - 0.7 * dense)
            if feel.burst {
                // sine bursts: whole cycles, ~45 % duty
                let cyc = max(2, (0.050 * Double(hz)).rounded())
                let ms = Float(min(70, cyc / Double(hz) * 1000))
                let level = min(0.55, 0.8 * gain * (0.5 + 0.5 * strength))
                let period = Double(ms) * 0.001 / MusicStyle.textureDutyBurst
                texDue = max(texDue + period, now + Double(ms) * 0.001)
                if level > 0.06 && dutyMS(now) + Double(ms) <= MusicStyle.dutyBudgetMS {
                    texLastDrive = now
                    counts[MusicLayer.texture.rawValue] += 1; book(now, Double(ms), .texture, level / 0.8)
                    return .sine(hz, ms, level)
                }
            } else {
                let amp = MusicStyle.textureAmpMax * gain
                let w = max(3, min(feel.texWidthMax, Float(MusicStyle.textureDutyPulse * 1000) / hz))
                texDue = max(texDue + Double(1 / hz), now + Double(w) * 0.001)
                if amp > 3.5 && dutyMS(now) + Double(w) <= MusicStyle.dutyBudgetMS {
                    texLastDrive = now
                    counts[MusicLayer.texture.rawValue] += 1; book(now, Double(w), .texture, amp / 48)
                    return .pulse(amp, w, lvl)
                }
            }
        }
        // melody / vocal emphasis: very light pulse train in sparse passages at high detail
        if detail >= (quiet ? 0.75 : 0.6) && !f.silent && f.flux < 0.25 && f.level > 0.4 && f.peaks.y > 0.2 && envEff < 0.2
            && tapRate < 1.2 && now - lastTapAt > 0.15 && now >= melDue && dutyMS(now) < 300 {
            var tgt = log2f(Self.fold(max(100, f.peaks.x), lo: 35, hi: 70))
            if melHave { tgt = melLog2 + max(-0.1, min(0.1, (tgt - melLog2) * 0.3)) }
            melLog2 = tgt; melHave = true
            let hz = exp2f(tgt)
            let amp = 5 + (MusicStyle.melodyAmpMax - 5) * c01(f.peaks.y) * c01(f.level) * detail
            melDue = now + Double(1 / hz)
            counts[MusicLayer.melody.rawValue] += 1; book(now, 5, .melody, amp / 48)
            return .pulse(amp, 5, lvl)
        }
        if !(detail >= 0.6) || f.flux >= 0.25 || f.level <= 0.4 { melHave = false }
        return nil
    }

    /// Plays an action on the motor. Returns the MT status (0 = ok, negative = refused by the governor).
    @discardableResult func execute(_ act: MotorAct, on motor: TrackpadMotor) -> Int32 {
        switch act {
        case .tones(let a, let b, let lv): return motor.playSegs(a, b, nil, level: lv)
        case .waveform(let id):
            let rc = motor.systemWaveform(id: id)
            if rc == -1 && !motor.hasWaveforms { hasWaveforms = false }
            return rc
        case .impulse(let ms, let lv): return motor.impulse(ms: ms, level: lv)
        case .pulse(let a, let w, let lv): return motor.pulse(amplitude: a, widthMS: w, level: lv)
        case .sine(let hz, let ms, let lv): return motor.sine(hz: hz, ms: ms, level: lv)
        }
    }
}
