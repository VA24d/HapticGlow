// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow - movie-mode planner (cinema LFE impacts and sustained sub-bass rumble).
//
// Pure logic, no motor access: `observe` ingests raw capture-time frames to detect impacts against
// a slow adaptive baseline, and `tick` is called by HapticEngine's realtime loop (and offline eval
// harnesses) returning at most ONE motor action per call.
//
// Cinema behavior vs. music:
//   - Dialogue and quiet underscore stay silent (speech dominance gate + physical LFE floor + slow
//     multi-second baseline).
//   - Impacts (explosions, Kaiju footsteps, slams): strong wide Gaussian onset pulse (26-48 amp,
//     10-12 ms) synced to captureTime + SyncClock.delay - motorLatency, followed by a low 34-46 Hz
//     sine body and a slow-decaying sub-bass rumble tail.
//   - Sustained LFE passages (engines, roars, collapses): 30-50 Hz Gaussian pulse train or low sine
//     bursts following the sub-bass envelope, proactively tapered and rested before the motor
//     governor's 2 s / 60% duty limits.
import Foundation

struct ImpactEvent: Sendable {
    var time: Double       // capture-clock time of the impact onset
    var strength: Float    // 0...1 normalized impact severity
    var subPeak: Float     // 0...1 sub-bass level at trigger
}

enum MovieLayer: Int, Sendable { case impact, impactBody, rumble }

enum MovieStyle {
    // ---- impact gating
    static let impactMinGap = 0.80        // seconds between distinct impact onset pulses
    static let decayGuardWindow = 0.75    // seconds where weaker echoes are suppressed
    static let decayGuardRatio: Float = 0.65

    // ---- adaptive baseline time constants (seconds)
    static let baseUpTau: Float = 4.5
    static let baseDownTau: Float = 2.0
    static let baseMaxLfe: Float = 0.36
    static let preUpTau: Float = 0.22
    static let preDownTau: Float = 0.030

    // ---- absolute cinema floors (prevent dialogue / light score from triggering)
    static let minSubDB: Float = 0.80     // 20-60 Hz within ~10 dB of peak band
    static let minBelowCutoff: Float = 0.50
    static let minLevel: Float = 0.55
    static let minLfe: Float = 0.62
    static let impactJump: Float = 0.38   // lfe jump over the slow baseline
    static let impactRatio: Float = 2.7
    static let impactPreJump: Float = 0.20
    // rumble gate
    static let rumbleFloor: Float = 0.55
    static let rumbleBaseMul: Float = 1.5
    static let rumbleStrong: Float = 0.72

    // ---- rumble envelope
    static let rumbleAttackTau: Float = 0.025
    static let rumbleReleaseTau: Float = 0.38
    static let rumbleSilentReleaseTau: Float = 0.14

    // ---- proactive governor safety margins (well inside 2000 ms run / 600 ms duty / 200 acts/s)
    static let dutyBudgetMS = 480.0
    static let dutyCeilingMS = 540.0
    static let rumbleRunMax = 1.45
    static let rumbleTaperFrom = 0.85
    static let rumbleRest = 0.32
}

final class MoviePlanner {
    // stats (read by offline eval / diagnostics)
    /// Actuation counts per layer: impact, impactBody, rumble.
    private(set) var counts = [UInt64](repeating: 0, count: 3)
    /// Nominal actuating milliseconds per layer (same order as `counts`).
    private(set) var layerMS = [Double](repeating: 0, count: 3)
    private(set) var impactsDetected: UInt64 = 0
    private(set) var impactsFired: UInt64 = 0
    private(set) var dropped: UInt64 = 0
    private(set) var masked: UInt64 = 0
    private(set) var retriggerBlocked: UInt64 = 0
    private(set) var lastLayer: MovieLayer = .rumble
    private(set) var lastLevel: Float = 0

    /// Audio-to-ear delay the planner schedules against (SyncClock; override for tests).
    var delayOverride: Double?
    func syncDelay() -> Double { delayOverride ?? SyncClock.shared.delay }
    func featureTime(now: Double) -> Double { now - syncDelay() + HapticTuning.motorLatency + HapticTuning.featureLead }

    // capture-time impact detector state
    private var lastObs = -1.0
    private var baseLfe: Float = 0.05
    private var preLfe: Float = 0
    private var prevLfe: Float = 0
    private var baseLevel: Float = 0.4
    private var baseFlux: Float = 0.08
    private var armed = true
    private var pkSince: Float = 0
    private var lastImpactT = -10.0
    private var lastImpactStr: Float = 0

    // pending impact queue & follow-up body steps
    private struct Pending { var e: ImpactEvent; var due: Double }
    private struct Step { var at: Double; var act: MotorAct; var layer: MovieLayer; var lvl: Float; var ms: Double }
    private var pend: [Pending] = { var a = [Pending](); a.reserveCapacity(32); return a }()
    private var steps: [Step] = { var a = [Step](); a.reserveCapacity(4); return a }()

    // own actuation log for the duty budget: (time, ms)
    private var actLog: [(t: Double, ms: Double)] = { var a = [(t: Double, ms: Double)](); a.reserveCapacity(256); return a }()

    // delayed rumble state (scheduler clock)
    private var lastTick = 0.0
    private var dLastObs = -1.0
    private var dBaseLfe: Float = 0.05
    private var rumbleEnv: Float = 0
    private var rumbleDue = 0.0
    private var busyUntil = 0.0
    private var log2Hz: Float = log2f(38)
    private var haveHz = false
    private var lastImpactFireAt = -10.0

    // proactive continuous-run guard
    private var runStart = 0.0
    private var runLastDrive = 0.0
    private var restUntil = 0.0

    func reset() {
        pend.removeAll(keepingCapacity: true)
        steps.removeAll(keepingCapacity: true)
        actLog.removeAll(keepingCapacity: true)
        lastObs = -1
        baseLfe = 0.05; preLfe = 0; prevLfe = 0; baseLevel = 0.4; baseFlux = 0.08
        armed = true; pkSince = 0; lastImpactT = -10; lastImpactStr = 0
        lastTick = 0; dLastObs = -1; dBaseLfe = 0.05
        rumbleEnv = 0; rumbleDue = 0; busyUntil = 0
        log2Hz = log2f(38); haveHz = false; lastImpactFireAt = -10
        runStart = 0; runLastDrive = 0; restUntil = 0
    }

    func resetStats() {
        for i in 0..<3 { counts[i] = 0; layerMS[i] = 0 }
        impactsDetected = 0; impactsFired = 0
        dropped = 0; masked = 0; retriggerBlocked = 0
    }

    /// True when no impacts or body steps are pending and rumble has settled.
    var isIdle: Bool { pend.isEmpty && steps.isEmpty && rumbleEnv < 0.01 }

    /// Queue a single full-strength impact for the UI Test button.
    func triggerTestImpact(now: Double) {
        let e = ImpactEvent(time: now - syncDelay() + HapticTuning.motorLatency, strength: 0.9, subPeak: 0.9)
        if pend.count < 32 { pend.append(Pending(e: e, due: now)) }
    }

    @inline(__always) private func c01(_ x: Float) -> Float { max(0, min(1, x)) }

    private func lateLimit(_ delay: Double) -> Double {
        delay < HapticTuning.shortDelay ? HapticTuning.lateToleranceShort : HapticTuning.lateTolerance
    }

    /// Convert 48 dB-normalised band value back to linear amplitude relative to the peak band,
    /// then weight by `belowCutoff` (which carries an absolute 0.03 amplitude floor) to separate
    /// genuine cinema LFE from dialogue and quiet underscore.
    @inline(__always)
    static func cinemaMetrics(_ f: AudioFeatures) -> (subLin: Float, lfe: Float, speechDominant: Bool) {
        // f.sub = 20-60 Hz in [-48 dB, 0 dB] relative to peak band
        let subLin = powf(10, 2.4 * (max(0, min(1, f.sub)) - 1))
        let b02 = (f.bands[0] + f.bands[1] + f.bands[2]) / 3
        let b02Lin = powf(10, 2.4 * (max(0, min(1, b02)) - 1))
        let bassLin = powf(10, 2.4 * (max(0, min(1, f.bass)) - 1))
        let subWeight = max(subLin, 0.72 * subLin + 0.28 * b02Lin)
        let lfe = f.belowCutoff * (0.78 * subWeight + 0.22 * bassLin) * (0.30 + 0.70 * f.level)
        let midLin = powf(10, 2.4 * (max(0, min(1, max(f.mid, f.lowMid))) - 1))
        let speechDominant = (subLin < 0.22 && midLin > subLin * 3.0 && f.belowCutoff < 0.42)
        return (subLin, lfe, speechDominant)
    }

    // MARK: capture-time impact detection

    /// Feed every raw (undelayed) analysis frame in chronological order.
    func observe(_ f: AudioFeatures) {
        if lastObs > 0 && f.time < lastObs - 1.0 { reset() }
        guard f.time > lastObs else { return }
        let dt = lastObs > 0 ? Float(min(0.1, f.time - lastObs)) : 0.00533
        lastObs = f.time

        if f.silent {
            if preLfe < 0.001 && abs(baseLfe - 0.02) < 0.002 && baseLevel < 0.001 && baseFlux < 0.001 {
                preLfe = 0; prevLfe = 0; baseLfe = 0.02; baseLevel = 0; baseFlux = 0
                armed = true; pkSince = 0
                return
            }
            preLfe *= expf(-dt / MovieStyle.preDownTau)
            prevLfe = 0
            baseLfe += (0.02 - baseLfe) * (1 - expf(-dt / MovieStyle.baseDownTau))
            baseLevel *= expf(-dt / 2.0)
            baseFlux *= expf(-dt / 1.5)
            armed = true; pkSince = 0
            return
        }

        let m = Self.cinemaMetrics(f)
        let bTau = m.lfe > baseLfe ? MovieStyle.baseUpTau : MovieStyle.baseDownTau
        let nextBase = baseLfe + (m.lfe - baseLfe) * (1 - expf(-dt / bTau))
        baseLfe = min(MovieStyle.baseMaxLfe, nextBase)

        let pTau = m.lfe > preLfe ? MovieStyle.preUpTau : MovieStyle.preDownTau
        preLfe += (m.lfe - preLfe) * (1 - expf(-dt / pTau))
        baseLevel += (f.level - baseLevel) * (1 - expf(-dt / 3.5))
        baseFlux += (f.flux - baseFlux) * (1 - expf(-dt / 2.0))

        if m.lfe > pkSince { pkSince = m.lfe }
        if !armed && (m.lfe < 0.65 * pkSince || (m.lfe - preLfe < 0.025 && f.time - lastImpactT >= 0.22)) {
            armed = true
        }

        let jumpOverBase = m.lfe - baseLfe
        let jumpOverPre = m.lfe - preLfe
        let stepRise = m.lfe - prevLfe
        prevLfe = m.lfe
        let ratioOverBase = m.lfe / max(0.04, baseLfe)
        let transient = f.flux >= 0.24
            || (f.flux - baseFlux) >= 0.11
            || (f.level - baseLevel) >= 0.06
            || (f.onset && f.onsetStrength >= 0.30)
            || stepRise >= 0.10
            || jumpOverPre >= 0.16

        if armed
            && f.time - lastImpactT >= MovieStyle.impactMinGap
            && !m.speechDominant
            && f.sub >= MovieStyle.minSubDB
            && f.belowCutoff >= MovieStyle.minBelowCutoff
            && f.level >= MovieStyle.minLevel
            && m.lfe >= MovieStyle.minLfe
            && jumpOverBase >= MovieStyle.impactJump
            && ratioOverBase >= MovieStyle.impactRatio
            && jumpOverPre >= MovieStyle.impactPreJump
            && transient
        {
            // span the gate-pass range so a marginal hit is clearly weaker than a huge one
            let raw = c01(0.50 * c01((m.lfe - MovieStyle.minLfe) / 0.55)
                        + 0.35 * c01((jumpOverBase - MovieStyle.impactJump) / 0.45)
                        + 0.15 * c01((f.belowCutoff - MovieStyle.minBelowCutoff) / 0.4))
            let strength = max(0.35, min(1.0, 0.38 + 0.62 * powf(raw, 0.85)))
            if f.time - lastImpactT < MovieStyle.decayGuardWindow && strength < MovieStyle.decayGuardRatio * lastImpactStr {
                retriggerBlocked += 1
                return
            }
            lastImpactT = f.time
            lastImpactStr = strength
            armed = false
            pkSince = m.lfe
            impactsDetected += 1

            let due = f.time + syncDelay() - HapticTuning.motorLatency
            if pend.count >= 32 { pend.removeFirst(); dropped += 1 }
            pend.append(Pending(e: ImpactEvent(time: f.time, strength: strength, subPeak: f.sub), due: due))
        }
    }

    // MARK: duty bookkeeping

    private func dutyMS(_ now: Double) -> Double {
        var s = 0.0
        var k = 0
        for r in actLog { if r.t + r.ms * 0.001 < now - 1 { k += 1 } else { break } }
        if k > 0 { actLog.removeFirst(k) }
        for r in actLog {
            let a = max(r.t, now - 1), b = min(r.t + r.ms * 0.001, now)
            if b > a { s += (b - a) * 1000 }
        }
        return s
    }

    private func book(_ now: Double, _ ms: Double, _ layer: MovieLayer, _ lvl: Float, high: Bool) {
        if let l = actLog.last, l.t + l.ms * 0.001 > now {
            actLog[actLog.count - 1].ms = max(0, (now - l.t) * 1000)
        }
        actLog.append((now, ms))
        layerMS[layer.rawValue] += ms
        counts[layer.rawValue] += 1
        lastLayer = layer; lastLevel = lvl
        busyUntil = now + ms * 0.001
        if high {
            if runStart == 0 || now - runLastDrive > 0.041 { runStart = now }
            runLastDrive = now + ms * 0.001
        }
    }

    // MARK: tick

    /// One scheduler step. `f` must already be the delayed feature frame (`featureTime(now:)`).
    func tick(now: Double, f: AudioFeatures, cfg c: HapticConfig) -> MotorAct? {
        let strength = c01(c.strength), rumbleCtrl = c01(c.rumble)
        let dt = lastTick > 0 ? max(0, min(0.05, now - lastTick)) : 0.005
        lastTick = now
        let delay = syncDelay()
        let late = lateLimit(delay)

        if f.silent && pend.isEmpty && steps.isEmpty && rumbleEnv < 0.005 {
            if f.time > dLastObs || dLastObs < 0 {
                let dDt = dLastObs > 0 ? Float(max(0.001, min(0.1, f.time - dLastObs))) : Float(max(0.001, dt))
                dLastObs = f.time
                if abs(dBaseLfe - 0.02) >= 0.002 {
                    dBaseLfe += (0.02 - dBaseLfe) * (1 - expf(-dDt / MovieStyle.baseDownTau))
                } else { dBaseLfe = 0.02 }
            }
            rumbleEnv = 0; haveHz = false; runStart = 0
            if !actLog.isEmpty { _ = dutyMS(now) }
            return nil
        }

        // Drop stale impact events
        var i = 0
        while i < pend.count {
            if now - pend[i].due > late { pend.swapAt(i, pend.count - 1); pend.removeLast(); dropped += 1 }
            else { i += 1 }
        }

        // Update delayed rumble envelope from synced frame `f`
        let m = f.silent ? (subLin: Float(0), lfe: Float(0), speechDominant: false) : Self.cinemaMetrics(f)
        if f.time > dLastObs || dLastObs < 0 {
            let dDt = dLastObs > 0 ? Float(max(0.001, min(0.1, f.time - dLastObs))) : Float(max(0.001, dt))
            dLastObs = f.time
            if f.silent {
                dBaseLfe += (0.02 - dBaseLfe) * (1 - expf(-dDt / MovieStyle.baseDownTau))
            } else {
                let bTau = m.lfe > dBaseLfe ? MovieStyle.baseUpTau : MovieStyle.baseDownTau
                dBaseLfe = min(MovieStyle.baseMaxLfe, dBaseLfe + (m.lfe - dBaseLfe) * (1 - expf(-dDt / bTau)))
            }
        }
        var rawRumble: Float = 0
        if !f.silent && !m.speechDominant && f.sub >= MovieStyle.minSubDB && f.belowCutoff >= 0.46 && f.level >= 0.5 {
            if m.lfe > max(MovieStyle.rumbleFloor, dBaseLfe * MovieStyle.rumbleBaseMul) || m.lfe >= MovieStyle.rumbleStrong {
                rawRumble = powf(c01((m.lfe - 0.36) / 0.60), 0.78)
            }
        }
        let rTau = rawRumble > rumbleEnv ? MovieStyle.rumbleAttackTau : (f.silent ? MovieStyle.rumbleSilentReleaseTau : MovieStyle.rumbleReleaseTau)
        rumbleEnv += (rawRumble - rumbleEnv) * (1 - expf(-Float(max(0.001, dt)) / rTau))
        if now - runLastDrive > 0.041 { runStart = 0 }

        if strength < 0.02 { return nil }

        // ---- 1. Fire due impact onset pulse
        // During a forced rest, an impact may only start once a >40 ms gap exists (else the governor sees one long run).
        let inRestRun = now < restUntil && now - runLastDrive <= 0.041
        if !inRestRun, let idx = pend.firstIndex(where: { now >= $0.due }) {
            let p = pend[idx]
            pend.remove(at: idx)
            if now - lastImpactFireAt < MovieStyle.impactMinGap {
                masked += 1
            } else {
                // Respect proactive rest if we somehow drove right up to 1.85 s
                let held = runStart > 0 ? (now - runStart) : 0
                if held >= 1.60 {
                    restUntil = now + MovieStyle.rumbleRest
                    runStart = 0
                    masked += 1
                    return nil
                }
                lastImpactFireAt = now
                steps.removeAll(keepingCapacity: true)
                let I = p.e.strength
                rumbleEnv = max(rumbleEnv, 0.32 + 0.45 * I)

                let width = min(MotorLimits.maxWidthMS, 10 + 2 * I)
                if dutyMS(now) + Double(width) <= MovieStyle.dutyCeilingMS {
                    let amp = min(MotorLimits.maxGaussian, 26 + 22 * I)
                    // Queue a weighty low-sine body right behind the Gaussian punch
                    if rumbleCtrl > 0.05 && dutyMS(now) < 460 && held < 1.55 {
                        let baseHz: Float = c.feel == .crisp ? 46 : (c.feel == .punchy ? 42 : 36)
                        let hz = min(c.quiet ? HapticTuning.quietMaxHz : 90, max(MotorLimits.minToneHz, baseHz))
                        let targetMS: Float = 52 + 22 * I
                        let cyc = max(1, (targetMS * hz / 1000).rounded(.down))
                        let bodyMS = min(MotorLimits.maxToneMS, cyc / hz * 1000)
                        let bodyLvl = min(MotorLimits.maxToneLevel, (0.40 + 0.40 * I) * (0.5 + 0.5 * strength) * (0.45 + 0.55 * rumbleCtrl))
                        if bodyMS >= 22 && bodyLvl >= 0.08 {
                            steps.append(Step(at: p.due + 0.005, act: .sine(hz, bodyMS, bodyLvl), layer: .impactBody, lvl: bodyLvl / MotorLimits.maxToneLevel, ms: Double(bodyMS)))
                        }
                    }
                    impactsFired += 1
                    let effLvl = amp * strength / MotorLimits.maxGaussian
                    book(now, Double(width), .impact, effLvl, high: amp * strength >= MotorLimits.highPulseEnergy)
                    return .pulse(amp, width, strength)
                } else {
                    masked += 1
                }
            }
        }

        // ---- 2. Follow-up impact body
        if let s = steps.first, now >= s.at {
            steps.removeFirst()
            if now - s.at <= 0.04 && dutyMS(now) + s.ms <= MovieStyle.dutyCeilingMS {
                book(now, s.ms, s.layer, s.lvl, high: s.lvl * MotorLimits.maxToneLevel >= MotorLimits.highToneLevel)
                return s.act
            }
        }

        // ---- 3. Sustained / decaying sub-bass rumble (30-50 Hz)
        if now < busyUntil || !steps.isEmpty || now < rumbleDue || now < restUntil { return nil }
        if pend.contains(where: { $0.due - now < 0.015 && $0.due >= now }) { return nil }
        guard rumbleCtrl > 0.02, rumbleEnv > 0.16 else { return nil }

        if runStart == 0 || now - runLastDrive > 0.041 { runStart = now }
        let held = now - runStart
        if held >= MovieStyle.rumbleRunMax {
            restUntil = now + MovieStyle.rumbleRest
            runStart = 0
            return nil
        }
        let taper = 1 - 0.38 * c01(Float((held - MovieStyle.rumbleTaperFrom) / (MovieStyle.rumbleRunMax - MovieStyle.rumbleTaperFrom)))

        // Smooth rumble pitch in 30-50 Hz
        let lowWeight = f.bands[0] + f.bands[1] + 1e-4
        let hiWeight = f.bands[3] + f.bands[4] + 1e-4
        let ratio = hiWeight / (lowWeight + hiWeight)
        var targetHz = 31 + 16 * ratio
        if f.bassPitchHz >= 25 && f.bassPitchHz <= 120 {
            let folded = MusicPlanner.fold(f.bassPitchHz, lo: 30, hi: 60)
            targetHz = max(30, min(50, folded))
        }
        let tgtLog = log2f(max(30, min(50, targetHz)))
        if !haveHz { log2Hz = tgtLog; haveHz = true }
        else {
            let maxStep = 0.45 * Float(max(dt, 0.001)) / 0.020
            log2Hz += max(-maxStep, min(maxStep, (tgtLog - log2Hz) * 0.25))
        }
        let hz = max(30, min(50, exp2f(log2Hz)))
        let rAmp = c01(rumbleEnv * rumbleCtrl * taper)

        if c.feel == .punchy {
            // Low sine bursts (34-50 Hz), ~45% duty
            let cyc = max(2, (0.052 * Double(hz)).rounded())
            let ms = Float(min(Double(MotorLimits.maxToneMS), cyc / Double(hz) * 1000))
            let lv = min(0.75, (0.14 + 0.60 * rAmp) * strength)
            let period = Double(ms) * 0.001 / 0.45
            rumbleDue = max(rumbleDue + period, now + Double(ms) * 0.001)
            if lv >= 0.08 && dutyMS(now) + Double(ms) <= MovieStyle.dutyBudgetMS {
                book(now, Double(ms), .rumble, lv / MotorLimits.maxToneLevel, high: lv >= MotorLimits.highToneLevel)
                return .sine(hz, ms, lv)
            }
        } else {
            // Gaussian pulse train at 30-50 Hz (deep: wide 10-12 ms; crisp: 7-9 ms)
            let maxDutyW = Float(0.42 * 1000.0 / Double(hz))
            let baseW: Float = c.feel == .crisp ? 8.5 : 11.5
            let w = max(MotorLimits.minWidthMS, min(MotorLimits.maxWidthMS, min(baseW, maxDutyW)))
            let amp = min(46, 8 + 38 * rAmp)
            let period = Double(1 / hz)
            rumbleDue = max(rumbleDue + period, now + Double(w) * 0.001)
            if amp * strength >= 5 && dutyMS(now) + Double(w) <= MovieStyle.dutyBudgetMS {
                book(now, Double(w), .rumble, amp * strength / MotorLimits.maxGaussian, high: amp * strength >= MotorLimits.highPulseEnergy)
                return .pulse(amp, w, strength)
            }
        }
        return nil
    }

    /// Plays an action on the motor. Returns the MT status (0 = ok, negative = refused by the governor).
    @discardableResult func execute(_ act: MotorAct, on motor: TrackpadMotor) -> Int32 {
        switch act {
        case .tones(let a, let b, let lv): return motor.playSegs(a, b, nil, level: lv)
        case .waveform(let id): return motor.systemWaveform(id: id)
        case .impulse(let ms, let lv): return motor.impulse(ms: ms, level: lv)
        case .pulse(let a, let w, let lv): return motor.pulse(amplitude: a, widthMS: w, level: lv)
        case .sine(let hz, let ms, let lv): return motor.sine(hz: hz, ms: ms, level: lv)
        }
    }
}
