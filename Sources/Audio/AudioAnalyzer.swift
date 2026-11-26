// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// AudioAnalyzer: low-latency music analysis (Accelerate/vDSP). Public API is frozen.
//
// Credits: the per-sample kick onset path (RBJ low-pass, 3 ms / 90 ms envelope, 500 ms moving
// average, rising-edge arm/rearm, relative threshold, refractory) is ported from MagicKey's
// OnsetDetector (MIT, XiaoSong1223). Everything else is original.
//
// Pipeline (hop = 256 samples, FFT 2048 Hann recomputed every hop, all buffers preallocated):
//   per-sample : onset LP + envelope, below-cutoff envelope (2x biquad), hop RMS
//   per-hop FFT: 5 bands, 32 log bands, low-band spectral flux (secondary onset path, never fires
//                on held notes because it looks at total 40-150 Hz energy, not per-bin changes),
//                bass pitch (magnitude peak + phase-vocoder refinement), two mid peaks
//   tempo      : autocorrelation of an 8 s onset-impulse envelope with harmonic comb, folded to
//                70-180 BPM, refined by least-squares fit of onset times to a beat grid.

import Foundation
import Accelerate
import AVFoundation
import Synchronization

// MARK: - Core (one instance per stream; not thread safe, owner serialises)

/// Analyzer timing/threshold knobs (tune after real-music measurement).
enum AnalyzerTuning {
    /// The envelope-threshold onset fires after the true attack start (filter group delay + rise to 1.35x the average);
    /// measured +9...+20 ms late against a non-causal low-band + click-band reference on five Weeknd tracks. The reported
    /// onset time is moved this much earlier (seconds). Safe because haptics are delayed by SyncClock.delay anyway.
    static var envOnsetLead = 0.012
    /// Attack-start backtracking: the reported onset is where the envelope was still `backFrac` of the way up from
    /// the pre-hit level to its value at the trigger, minus `backLead` for the envelope/filter lag. Replaces the
    /// fixed lead (set `backtrack = false` to get it back). Slow-rising kicks and 808s now get earlier times than
    /// sharp ones instead of one constant for all.
    static var backtrack = true
    static var backFrac: Float = 0.2
    static var backLead = 0.002
    static var backMax = 0.050
}

final class AnalyzerCore {
    static let hop = 256
    static let fftN = 2048
    static let half = 1024
    static let nBands = 32
    static let logN = 11

    let live: Bool
    private(set) var sr: Double = 48000
    var fixedCutoff: Float = 120
    var fixedSens: Float = 1
    var onFrame: ((AudioFeatures) -> Void)?

    // timing diag
    var avgHopMs: Double = 0
    private var tb = mach_timebase_info_data_t()

    // buffers (all preallocated)
    private let hopBuf: UnsafeMutablePointer<Float>
    private var hopFill = 0
    private let hopHalf = AnalyzerCore.hop / 2
    private var hopHalfDone = false, hopCommitted = false
    private var hopOnsetIdx = -1, hopOnsetBack = 0
    private var hopOnsetStr: Float = 0
    private var lastFrame = AudioFeatures()
    private(set) var fastMs: Double = 0
    /// Read on the IO thread once per half hop; written only from setOnsetDemand and the power observer.
    static let fastOnsetEnabled = Atomic<Bool>(true)
    private let frame: UnsafeMutablePointer<Float>       // last 2048 samples, linear
    private let win: UnsafeMutablePointer<Float>
    private let tmp: UnsafeMutablePointer<Float>
    private let re: UnsafeMutablePointer<Float>
    private let im: UnsafeMutablePointer<Float>
    private let p: UnsafeMutablePointer<Float>           // amplitude^2 per bin
    private let prevRe: UnsafeMutablePointer<Float>
    private let prevIm: UnsafeMutablePointer<Float>
    private let fftSetup: FFTSetup
    private var havePrev = false

    // band tables
    private let bStart: UnsafeMutablePointer<Int32>
    private let bEnd: UnsafeMutablePointer<Int32>
    private let bCenter: UnsafeMutablePointer<Float>
    private let bTilt: UnsafeMutablePointer<Float>
    private let fiveLo = UnsafeMutablePointer<Int32>.allocate(capacity: 5)
    private let fiveHi = UnsafeMutablePointer<Int32>.allocate(capacity: 5)
    private var binHz: Float = 48000 / 2048

    // smoothed outputs
    private var bands5 = [Float](repeating: 0, count: 5)
    private var bands32 = [Float](repeating: 0, count: 32)
    private var ref5: Float = -40, ref32: Float = -40
    private var relCoef: Float = 0
    private var levelEnv: Float = 0, levelRef: Float = -35, levelOut: Float = 0
    private var silentSamples = 0
    private var isSilent = true

    // onset (per sample)
    private var ob0 = 0.0, ob1 = 0.0, ob2 = 0.0, oa1 = 0.0, oa2 = 0.0
    private var ox1 = 0.0, ox2 = 0.0, oy1 = 0.0, oy2 = 0.0
    private var oEnv: Float = 0, oAvg: Float = 0, oPeak: Float = 0
    private var oAttack: Float = 0, oRelease: Float = 0, oAvgC: Float = 0, oPeakC: Float = 0
    private var oArmed = true
    private var oPkSince: Float = 0     // envelope peak since the last onset (re-arm on a clear decay even above a held sub note)
    private var sinceOnset = Int.max / 2
    private var refractory = 5280
    private let envHist = UnsafeMutablePointer<Float>.allocate(capacity: 16)   // env per hop (rise test)
    private var envHistPos = 0
    private let envRing: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 8192); p.initialize(repeating: 0, count: 8192); return p }()   // per-sample onset envelope (backtracking)

    // flux onset
    private var prevLowE: Float = 1e-9
    private let fluxHist = UnsafeMutablePointer<Float>.allocate(capacity: 96)
    private let fluxSort = UnsafeMutablePointer<Float>.allocate(capacity: 96)
    private var fluxPos = 0, fluxCount = 0
    private var fluxPrev: Float = 0
    private var lowEOnsetPeak: Float = 0
    private var fluxArmed = true

    // transient bands (snare / hat) + full-band flux: short 512-pt FFT, tail-light window so a new
    // attack is visible in the very hop it lands in (hop = 256 -> <= ~5 ms detection lag)
    static let tN = 512
    private let tFFT: FFTSetup
    private let tWin = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let tTmp = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let tRe = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let tIm = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let tCur = UnsafeMutablePointer<Float>.allocate(capacity: 260)
    private let tPrev = UnsafeMutablePointer<Float>.allocate(capacity: 260)
    private let sHist = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    private let hHist = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    private let tSort = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    private var tHave = false, tWarm = 0
    private var sLo = 2, sHi = 21, hLo = 54, hHi = 170
    private var sPos = 0, hPos = 0, tCount = 0
    private var sArmed = true, hArmed = true
    private var sinceSnare = Int.max / 2, sinceHat = Int.max / 2
    private var snareCount: UInt64 = 0, hatCount: UInt64 = 0
    private var fluxPk: Float = 1e-3, fluxOut: Float = 0
    private var centroidOut: Float = 0.4
    private var lastSnareOut = 0.0, lastHatOut = 0.0

    // below cutoff (2 cascaded biquads) + normaliser
    private var cutoffCur: Float = -1
    private var cb0 = 0.0, cb1 = 0.0, cb2 = 0.0, ca1 = 0.0, ca2 = 0.0
    private var cs = [Double](repeating: 0, count: 8)   // x1,x2,y1,y2 per stage
    private var cEnv: Float = 0
    private var cAtt: Float = 0, cRel: Float = 0
    private var cRef: Float = 0.05
    private var cRefDecay: Float = 0

    // pitch / peaks
    private var pitchOut: Float = 0
    private var peakRef: Float = -45
    private var peaksOut = SIMD4<Float>()

    // onsets & tempo
    private var onsetCount: UInt64 = 0
    private var lastOnsetStream: Double = 0     // seconds on the stream axis
    private var lastOnsetOut: Double = 0
    private let oTimes = UnsafeMutablePointer<Double>.allocate(capacity: 64)
    private let oStr = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    private var oN = 0, oHead = 0
    private let envAC = UnsafeMutablePointer<Float>.allocate(capacity: 800)
    private let acv = UnsafeMutablePointer<Float>.allocate(capacity: 800)
    private var bpmCur: Float = 0
    private var bpmPending: Float = 0
    private var bpmPendingN = 0
    private var bpmConf: Float = 0
    private var gridT0: Double = 0, gridT: Double = 0
    private var lowConfCount = 0
    private var nextEval = 0

    private var sampleCount: Int64 = 0
    private var pendingAfter = 0
    private var hopIndex = 0

    var tempoDebug: (conf: Float, bpm: Float) { (bpmConf, bpmCur) }

    init(live: Bool, sampleRate: Double) {
        self.live = live
        let h = AnalyzerCore.hop, n = AnalyzerCore.fftN
        hopBuf = .allocate(capacity: h); hopBuf.initialize(repeating: 0, count: h)
        frame = .allocate(capacity: n); frame.initialize(repeating: 0, count: n)
        win = .allocate(capacity: n)
        tmp = .allocate(capacity: n); tmp.initialize(repeating: 0, count: n)
        re = .allocate(capacity: n / 2); re.initialize(repeating: 0, count: n / 2)
        im = .allocate(capacity: n / 2); im.initialize(repeating: 0, count: n / 2)
        p = .allocate(capacity: n / 2 + 2); p.initialize(repeating: 0, count: n / 2 + 2)
        prevRe = .allocate(capacity: 128); prevRe.initialize(repeating: 0, count: 128)
        prevIm = .allocate(capacity: 128); prevIm.initialize(repeating: 0, count: 128)
        bStart = .allocate(capacity: 32); bEnd = .allocate(capacity: 32)
        bCenter = .allocate(capacity: 32); bTilt = .allocate(capacity: 32)
        for i in 0..<n { win[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))) }
        fftSetup = vDSP_create_fftsetup(vDSP_Length(AnalyzerCore.logN), FFTRadix(kFFTRadix2))!
        envHist.initialize(repeating: 0, count: 16)
        fluxHist.initialize(repeating: 0, count: 96); fluxSort.initialize(repeating: 0, count: 96)
        oTimes.initialize(repeating: 0, count: 64); oStr.initialize(repeating: 0, count: 64)
        envAC.initialize(repeating: 0, count: 800); acv.initialize(repeating: 0, count: 800)
        tFFT = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        for i in 0..<512 {
            tWin[i] = i < 416 ? Float(0.5 - 0.5 * cos(Double.pi * Double(i) / 416))
                              : Float(0.5 + 0.5 * cos(Double.pi * Double(i - 416) / 96))
        }
        tTmp.initialize(repeating: 0, count: 512); tRe.initialize(repeating: 0, count: 256); tIm.initialize(repeating: 0, count: 256)
        tCur.initialize(repeating: 0, count: 260); tPrev.initialize(repeating: 0, count: 260)
        sHist.initialize(repeating: 0, count: 64); hHist.initialize(repeating: 0, count: 64); tSort.initialize(repeating: 0, count: 64)
        mach_timebase_info(&tb)
        configure(sampleRate: sampleRate)
        resetState()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        hopBuf.deallocate(); frame.deallocate(); win.deallocate(); tmp.deallocate()
        re.deallocate(); im.deallocate(); p.deallocate(); prevRe.deallocate(); prevIm.deallocate()
        bStart.deallocate(); bEnd.deallocate(); bCenter.deallocate(); bTilt.deallocate()
        fiveLo.deallocate(); fiveHi.deallocate(); envHist.deallocate(); envRing.deallocate()
        fluxHist.deallocate(); fluxSort.deallocate(); oTimes.deallocate(); oStr.deallocate()
        envAC.deallocate(); acv.deallocate()
        vDSP_destroy_fftsetup(tFFT)
        tWin.deallocate(); tTmp.deallocate(); tRe.deallocate(); tIm.deallocate(); tCur.deallocate(); tPrev.deallocate()
        sHist.deallocate(); hHist.deallocate(); tSort.deallocate()
    }

    // MARK: configuration

    func configure(sampleRate: Double) {
        let s = max(8000, sampleRate)
        sr = s
        binHz = Float(s / Double(AnalyzerCore.fftN))
        let nyqBin = Float(AnalyzerCore.half - 1)
        // 5 bands
        let edges: [Float] = [20, 60, 160, 500, 2000, 16000]
        for i in 0..<5 {
            fiveLo[i] = Int32(max(1, Int((edges[i] / binHz).rounded(.up))))
            let hi = min(Float(AnalyzerCore.half), (edges[i + 1] / binHz).rounded(.up))
            fiveHi[i] = Int32(max(Float(fiveLo[i] + 1), hi))
        }
        // 32 log bands 30 Hz .. 16 kHz
        let fMax = min(16000, Float(s) * 0.48)
        let ratio = powf(fMax / 30, 1.0 / 32)
        for b in 0..<32 {
            let lo = 30 * powf(ratio, Float(b)), hi = lo * ratio
            let ctr = sqrtf(lo * hi)
            let lb = lo / binHz, hb = hi / binHz
            let sK = Int32(lb.rounded(.up)), eK = Int32((hb - 1e-4).rounded(.down))
            bStart[b] = max(1, sK); bEnd[b] = min(Int32(nyqBin), eK)
            bCenter[b] = min(nyqBin, ctr / binHz)
            bTilt[b] = 3 * log2f(ctr / 200)           // +3 dB/oct tilt so pink music reads flat
        }
        let hopT = Float(AnalyzerCore.hop) / Float(s)
        relCoef = expf(-hopT / 0.11)
        func c(_ sec: Double) -> Float { Float(exp(-1.0 / (sec * s))) }
        oAttack = c(0.003); oRelease = c(0.090); oAvgC = c(0.5); oPeakC = c(3.0)
        cAtt = c(0.003); cRel = c(0.040)
        cRefDecay = expf(-hopT / 8.0)
        refractory = Int(0.110 * s)
        setOnsetFilter(150)
        let tb = Float(s) / Float(AnalyzerCore.tN)
        sLo = max(1, Int((150 / tb).rounded(.up))); sHi = max(sLo + 3, Int((2000 / tb).rounded(.down)))
        hLo = Int((5000 / tb).rounded(.up)); hHi = min(255, Int((min(16000, Float(s) * 0.48) / tb).rounded(.down)))
        if hHi <= hLo + 4 { hLo = 200; hHi = 255 }
    }

    private func setOnsetFilter(_ fc: Double) {
        let w0 = 2 * Double.pi * min(fc, sr / 2 - 1) / sr
        let cw = cos(w0), al = sin(w0) / (2 * 0.70710678), a0 = 1 + al
        ob0 = (1 - cw) / 2 / a0; ob1 = (1 - cw) / a0; ob2 = ob0
        oa1 = -2 * cw / a0; oa2 = (1 - al) / a0
    }

    private func setCutoff(_ fc: Float) {
        cutoffCur = fc
        let w0 = 2 * Double.pi * min(Double(fc), sr / 2 - 1) / sr
        let cw = cos(w0), al = sin(w0) / (2 * 0.70710678), a0 = 1 + al
        cb0 = (1 - cw) / 2 / a0; cb1 = (1 - cw) / a0; cb2 = cb0
        ca1 = -2 * cw / a0; ca2 = (1 - al) / a0
    }

    func resetState() {
        hopFill = 0
        hopHalfDone = false; hopCommitted = false; hopOnsetIdx = -1; lastFrame = AudioFeatures()
        frame.update(repeating: 0, count: AnalyzerCore.fftN)
        havePrev = false
        for i in 0..<5 { bands5[i] = 0 }
        for i in 0..<32 { bands32[i] = 0 }
        ref5 = -40; ref32 = -40
        levelEnv = 0; levelRef = -35; levelOut = 0
        silentSamples = 0; isSilent = true
        ox1 = 0; ox2 = 0; oy1 = 0; oy2 = 0
        oEnv = 0; oAvg = 0; oPeak = 0; oArmed = true; oPkSince = 0; sinceOnset = Int.max / 2
        envHist.update(repeating: 0, count: 16); envHistPos = 0
        prevLowE = 1e-9; fluxPos = 0; fluxCount = 0; fluxPrev = 0; fluxArmed = true
        fluxHist.update(repeating: 0, count: 96)
        cutoffCur = -1
        for i in 0..<8 { cs[i] = 0 }
        cEnv = 0; cRef = 0.05
        pitchOut = 0; peakRef = -45; peaksOut = SIMD4<Float>()
        onsetCount = 0; lastOnsetStream = 0; lastOnsetOut = 0
        oN = 0; oHead = 0
        bpmCur = 0; bpmPending = 0; bpmPendingN = 0; bpmConf = 0; gridT = 0; gridT0 = 0; lowConfCount = 0
        sampleCount = 0; nextEval = 0; hopIndex = 0
        tHave = false; tWarm = 0; sPos = 0; hPos = 0; tCount = 0; sArmed = true; hArmed = true
        sinceSnare = Int.max / 2; sinceHat = Int.max / 2; snareCount = 0; hatCount = 0
        fluxPk = 1e-3; fluxOut = 0; centroidOut = 0.4; lastSnareOut = 0; lastHatOut = 0
        sHist.update(repeating: 0, count: 64); hHist.update(repeating: 0, count: 64)
        tPrev.update(repeating: 0, count: 260)
    }

    // MARK: input

    func process(_ x: UnsafePointer<Float>, count: Int) {
        var i = 0
        let h = AnalyzerCore.hop
        while i < count {
            let stop = hopFill < hopHalf ? hopHalf : h
            let n = min(stop - hopFill, count - i)
            (hopBuf + hopFill).update(from: x + i, count: n)
            hopFill += n; i += n
            if hopFill == hopHalf {
                // The half-hop scan only publishes onsets 128 samples earlier; with it off the whole hop is
                // scanned in runHop (same detector, same work, one publish less per onset).
                if AnalyzerCore.fastOnsetEnabled.load(ordering: .relaxed) {
                    pendingAfter = count - i
                    fastHalf()
                }
            } else if hopFill == h {
                pendingAfter = count - i
                runHop()
                hopFill = 0
            }
        }
    }

    /// Fast onset path: runs the per-sample onset detector over the first half of the hop as soon as it is
    /// in, and publishes an onset frame right away instead of waiting for the hop end (hop 256 -> 128).
    private func fastHalf() {
        let t0 = mach_absolute_time()
        scan(0, hopHalf, hopStart: sampleCount)
        hopHalfDone = true
        if hopOnsetIdx >= 0 && !isSilent {
            hopCommitted = true
            let sr = self.sr
            let lead = AnalyzerTuning.backtrack ? Double(hopOnsetBack) / sr + AnalyzerTuning.backLead : AnalyzerTuning.envOnsetLead
            let hopStart = sampleCount
            lastOnsetStream = Double(hopStart + Int64(hopOnsetIdx)) / sr - lead
            lastOnsetOut = live ? hostNow() - Double(hopHalf - hopOnsetIdx + pendingAfter) / sr - lead : lastOnsetStream
            onsetCount += 1
            oTimes[oHead] = lastOnsetStream; oStr[oHead] = max(0.2, hopOnsetStr)
            oHead = (oHead + 1) & 63; oN = min(64, oN + 1)
            var f = lastFrame
            f.time = live ? hostNow() : Double(hopStart + Int64(hopHalf)) / sr
            f.onset = true; f.onsetStrength = hopOnsetStr
            f.onsetCount = onsetCount; f.lastOnsetTime = lastOnsetOut
            if live { FeatureBus.shared.publish(f) }
            onFrame?(f)
        }
        let ms = Double(mach_absolute_time() &- t0) * Double(tb.numer) / Double(tb.denom) / 1e6
        fastMs = fastMs == 0 ? ms : fastMs * 0.995 + ms * 0.005
    }

    // MARK: hop

    /// Per-sample onset detector + below-cutoff envelope over hopBuf[lo..<hi]. Runs twice per hop
    /// (each half) so an onset in the first half is published 128 samples earlier than the hop end.
    private func scan(_ lo: Int, _ hi: Int, hopStart: Int64) {
        let sens = live ? FeatureBus.shared.sensitivity : fixedSens
        let thr = 1 + 0.35 / sqrtf(max(0.25, sens))
        let rearm = 1 + (thr - 1) * 0.3
        var onsetIdx = -1
        var onsetBack = 0
        var onsetStr: Float = 0
        var env = oEnv, avg = oAvg, pk = oPeak
        var x1 = ox1, x2 = ox2, y1 = oy1, y2 = oy2
        var ce = cEnv
        var s0x1 = cs[0], s0x2 = cs[1], s0y1 = cs[2], s0y2 = cs[3]
        var s1x1 = cs[4], s1x2 = cs[5], s1y1 = cs[6], s1y2 = cs[7]
        var armed = oArmed
        var pkSince = oPkSince
        var since = sinceOnset
        // rise reference: min envelope over the last ~30 ms (6 hops back)
        var envBefore: Float = .greatestFiniteMagnitude
        for k in 0..<6 { envBefore = min(envBefore, envHist[(envHistPos + 16 - 1 - k) & 15]) }
        for i in lo..<hi {
            let s = Double(hopBuf[i])
            let y = ob0 * s + ob1 * x1 + ob2 * x2 - oa1 * y1 - oa2 * y2
            x2 = x1; x1 = s; y2 = y1; y1 = y
            let mag = Float(abs(y))
            env = mag + (env - mag) * (mag > env ? oAttack : oRelease)
            envRing[Int((hopStart + Int64(i)) & 8191)] = env
            avg = env + (avg - env) * oAvgC
            pk = env > pk ? env : env + (pk - env) * oPeakC
            if since < Int.max / 2 { since += 1 }
            if env > pkSince { pkSince = env }
            if !armed && (env < rearm * avg || env < 0.7 * pkSince) { armed = true }
            // second leg: a hit on top of a held sub note (808) clears the 500 ms average late, but its
            // envelope still jumps well above where it was 30 ms ago, so it may fire once it is clearly rising
            let rising = env > 1.7 * envBefore && env > 1.05 * avg
            if armed && onsetIdx < 0 && env > 2.5e-4 && (env > thr * avg || rising) && since >= refractory
                && env > 1.25 * envBefore {
                since = 0; armed = false; pkSince = env
                onsetIdx = i
                onsetStr = pk > 0 ? min(1, env / pk) : 0
                if AnalyzerTuning.backtrack {
                    let base = envBefore < .greatestFiniteMagnitude ? min(envBefore, env) : 0
                    let level = base + AnalyzerTuning.backFrac * (env - base)
                    let maxBack = min(Int(AnalyzerTuning.backMax * sr), Int(hopStart) + i, 8000)
                    var back = 0
                    while back < maxBack && envRing[Int((hopStart + Int64(i - back - 1)) & 8191)] > level { back += 1 }
                    onsetBack = back
                }
            }
            // below cutoff: two cascaded biquads
            let u = Double(hopBuf[i])
            let v1 = cb0 * u + cb1 * s0x1 + cb2 * s0x2 - ca1 * s0y1 - ca2 * s0y2
            s0x2 = s0x1; s0x1 = u; s0y2 = s0y1; s0y1 = v1
            let v2 = cb0 * v1 + cb1 * s1x1 + cb2 * s1x2 - ca1 * s1y1 - ca2 * s1y2
            s1x2 = s1x1; s1x1 = v1; s1y2 = s1y1; s1y1 = v2
            let m2 = Float(abs(v2))
            ce = m2 + (ce - m2) * (m2 > ce ? cAtt : cRel)
        }
        oEnv = env; oAvg = avg; oPeak = pk
        ox1 = x1; ox2 = x2; oy1 = y1; oy2 = y2
        cEnv = ce
        cs[0] = s0x1; cs[1] = s0x2; cs[2] = s0y1; cs[3] = s0y2
        cs[4] = s1x1; cs[5] = s1x2; cs[6] = s1y1; cs[7] = s1y2
        oArmed = armed; sinceOnset = since; oPkSince = pkSince
        if onsetIdx >= 0 && hopOnsetIdx < 0 { hopOnsetIdx = onsetIdx; hopOnsetBack = onsetBack; hopOnsetStr = onsetStr }

    }

    private func runHop() {
        let t0 = mach_absolute_time()
        let h = AnalyzerCore.hop, n = AnalyzerCore.fftN
        let cutoff = live ? FeatureBus.shared.cutoffHz : fixedCutoff
        let sens = live ? FeatureBus.shared.sensitivity : fixedSens
        if cutoff != cutoffCur { setCutoff(cutoff) }

        let hopStart = sampleCount
        sampleCount += Int64(h)

        // slide frame, append hop
        memmove(frame, frame + h, (n - h) * MemoryLayout<Float>.size)
        (frame + (n - h)).update(from: hopBuf, count: h)

        // hop RMS
        var rms: Float = 0
        vDSP_rmsqv(hopBuf, 1, &rms, vDSP_Length(h))

        // ---- per-sample stage ----
        scan(hopHalfDone ? hopHalf : 0, h, hopStart: hopStart)
        hopHalfDone = false
        envHist[envHistPos & 15] = oEnv; envHistPos = (envHistPos + 1) & 15
        let onsetIdx = hopOnsetIdx, onsetBack = hopOnsetBack, onsetStr = hopOnsetStr

        // ---- silence gate ----
        if rms < 3e-4 { silentSamples += h } else { silentSamples = 0 }
        let silentNow = Double(silentSamples) / sr >= 0.3
        if silentNow && !isSilent {
            // fade state so the next music start has a clean slate
            oEnv = 0; oAvg = 0
        }
        isSilent = silentNow

        // ---- FFT ----
        vDSP_vmul(frame, 1, win, 1, tmp, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: re, imagp: im)
        tmp.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
        vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(AnalyzerCore.logN), FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, p, 1, vDSP_Length(n / 2))
        var sc: Float = 1 / Float((n / 2) * (n / 2))        // |2X|/(N/2) = amplitude
        vDSP_vsmul(p, 1, &sc, p, 1, vDSP_Length(n / 2))
        p[0] = 0
        p[n / 2] = 0

        // ---- bands ----
        computeBands(rms: rms)

        // ---- flux onset (secondary) ----
        var lowE: Float = 0
        let kLo = max(1, Int((40 / binHz).rounded())), kHi = max(kLo + 1, Int((150 / binHz).rounded()))
        for k in kLo...kHi { lowE += p[k] }
        lowE += 1e-9
        var flux: Float = 0
        if !isSilent { flux = max(0, 10 * log10f(lowE) - 10 * log10f(prevLowE)) }
        prevLowE = lowE
        // adaptive threshold = median of recent flux, floor
        let fn = min(fluxCount, 96)
        var med: Float = 0
        if fn >= 16 {
            fluxSort.update(from: fluxHist, count: fn)
            // partial selection via simple insertion sort (n <= 96)
            for a in 1..<fn { let v = fluxSort[a]; var b = a - 1; while b >= 0 && fluxSort[b] > v { fluxSort[b + 1] = fluxSort[b]; b -= 1 }; fluxSort[b + 1] = v }
            med = fluxSort[fn / 2]
        }
        let fluxThr = max(2.0, 4 * med) / sqrtf(max(0.5, sens))
        fluxHist[fluxPos] = flux; fluxPos = (fluxPos + 1) % 96; fluxCount += 1
        var fluxOnset = false
        if flux < fluxThr * 0.5 { fluxArmed = true }
        if fluxArmed && flux > fluxThr && flux >= fluxPrev && onsetIdx < 0 && !isSilent && lowE > 2e-6 {
            // only if no env onset is still inside the refractory window
            if sinceOnset >= refractory { fluxOnset = true; fluxArmed = false }
        }
        fluxPrev = flux

        // ---- commit onset ----
        var onset = false
        var strength: Float = 0
        if onsetIdx >= 0 && hopCommitted {
            // already published mid-hop by the fast path
        } else if onsetIdx >= 0 && !isSilent {
            onset = true; strength = onsetStr
            let lead = AnalyzerTuning.backtrack ? Double(onsetBack) / sr + AnalyzerTuning.backLead : AnalyzerTuning.envOnsetLead
            lastOnsetStream = Double(hopStart + Int64(onsetIdx)) / sr - lead
            lastOnsetOut = live ? hostNow() - Double(h - onsetIdx + pendingAfter) / sr - lead : lastOnsetStream
        } else if fluxOnset {
            onset = true
            strength = min(1, flux / 20)
            // Hann-windowed tail lags the true attack; back-date by ~1.2 hops (3 hops was 11 ms early on a
            // sample-exact synthetic kick train, see build/tests/haptic-lab/eval)
            let lag = Int(1.2 * Double(h))
            sinceOnset = lag
            lastOnsetStream = Double(sampleCount - Int64(lag)) / sr
            lastOnsetOut = live ? hostNow() - Double(lag + pendingAfter) / sr : lastOnsetStream
        }
        if onset {
            onsetCount += 1
            oTimes[oHead] = lastOnsetStream; oStr[oHead] = max(0.2, strength)
            oHead = (oHead + 1) & 63; oN = min(64, oN + 1)
        }

        // ---- bass pitch, peaks ----
        analysePitchAndPeaks(cutoff: cutoff)

        // ---- snare / hat transients, flux, centroid ----
        var snareStr: Float = 0, hatStr: Float = 0
        let kickRecent = sinceOnset < Int(0.035 * sr)
        transientBands(sens: sens, kickRecent: kickRecent, snare: &snareStr, hat: &hatStr)

        // ---- tempo ----
        hopIndex += 1
        if hopIndex >= nextEval {
            nextEval = hopIndex + Int(0.5 * sr / Double(h))
            evalTempo()
        }

        // ---- below cutoff normalised ----
        let cNow = cEnv
        cRef = max(0.03, max(cNow, cRef * cRefDecay))
        let below: Float = isSilent ? 0 : min(1, cNow / cRef)

        // ---- output ----
        var f = AudioFeatures()
        let tNow: Double = live ? hostNow() : Double(sampleCount) / sr
        f.time = tNow
        f.level = levelOut
        f.sub = bands5[0]; f.bass = bands5[1]; f.lowMid = bands5[2]; f.mid = bands5[3]; f.high = bands5[4]
        var b = SIMD32<Float>()
        for k in 0..<32 { b[k] = bands32[k] }
        f.bands = b
        f.belowCutoff = below
        f.bassPitchHz = isSilent ? 0 : pitchOut
        f.peaks = isSilent ? SIMD4<Float>() : peaksOut
        f.onset = onset
        f.onsetStrength = onset ? strength : 0
        f.onsetCount = onsetCount
        f.lastOnsetTime = lastOnsetOut
        f.bpm = bpmCur
        if bpmCur > 0 && gridT > 0 {
            let tt = Double(sampleCount) / sr
            var ph = (tt - gridT0) / gridT
            ph -= ph.rounded(.down)
            f.beatPhase = Float(ph)
        }
        f.silent = isSilent
        f.snareOnset = snareStr; f.hatOnset = hatStr
        f.snareCount = snareCount; f.hatCount = hatCount
        if snareStr > 0 { lastSnareOut = (live ? hostNow() - Double(pendingAfter) / sr : Double(sampleCount) / sr) - 0.0025 }
        if hatStr > 0 { lastHatOut = (live ? hostNow() - Double(pendingAfter) / sr : Double(sampleCount) / sr) - 0.0025 }
        f.lastSnareTime = lastSnareOut; f.lastHatTime = lastHatOut
        f.centroid = centroidOut; f.flux = fluxOut

        let t1 = mach_absolute_time()
        let ms = Double(t1 &- t0) * Double(tb.numer) / Double(tb.denom) / 1e6
        avgHopMs = avgHopMs == 0 ? ms : avgHopMs * 0.995 + ms * 0.005

        if live { FeatureBus.shared.publish(f) }
        lastFrame = f
        hopOnsetIdx = -1; hopCommitted = false
        onFrame?(f)
    }

    // MARK: bands

    private func computeBands(rms: Float) {
        // full-band level
        let rel = relCoef
        let lv = rms
        levelEnv = lv > levelEnv ? lv * 0.5 + levelEnv * 0.5 : lv + (levelEnv - lv) * expf(-Float(AnalyzerCore.hop) / Float(sr) / 0.15)
        let lvDB = 20 * log10f(levelEnv + 1e-9)
        if lvDB > levelRef { levelRef = lvDB } else { levelRef -= 0.012 }
        levelRef = max(levelRef, -35)
        let lOut = isSilent ? 0 : max(0, min(1, (lvDB - (levelRef - 32)) / 32))
        levelOut = lOut > levelOut ? lOut : lOut + (levelOut - lOut) * 0.9

        // 5 bands
        var dB5 = (Float(0), Float(0), Float(0), Float(0), Float(0))
        var m5: Float = -200
        withUnsafeMutableBytes(of: &dB5) { raw in
            let d = raw.bindMemory(to: Float.self)
            for i in 0..<5 {
                var s: Float = 0
                let a = Int(fiveLo[i]), b = Int(fiveHi[i])
                vDSP_sve(p + a, 1, &s, vDSP_Length(max(1, b - a)))
                d[i] = 10 * log10f(s + 1e-12)
                m5 = max(m5, d[i])
            }
            if m5 > ref5 { ref5 = m5 } else { ref5 -= 0.016 }
            ref5 = max(ref5, -40)
            for i in 0..<5 {
                let v = isSilent ? 0 : max(0, min(1, (d[i] - (ref5 - 48)) / 48))
                bands5[i] = v > bands5[i] ? v : v + (bands5[i] - v) * rel
            }
        }
        // 32 bands
        var m32: Float = -200
        for b in 0..<32 {
            var pw: Float
            let s = Int(bStart[b]), e = Int(bEnd[b])
            if e >= s {
                var sum: Float = 0
                vDSP_sve(p + s, 1, &sum, vDSP_Length(e - s + 1))
                pw = sum
            } else {
                let c = bCenter[b]
                let k0 = Int(c), fr = c - Float(k0)
                pw = p[k0] * (1 - fr) + p[min(k0 + 1, AnalyzerCore.half - 1)] * fr
            }
            let db = 10 * log10f(pw + 1e-12) + bTilt[b]
            acv[b] = db
            m32 = max(m32, db)
        }
        if m32 > ref32 { ref32 = m32 } else { ref32 -= 0.016 }
        ref32 = max(ref32, -40)
        for b in 0..<32 {
            let v = isSilent ? 0 : max(0, min(1, (acv[b] - (ref32 - 54)) / 54))
            bands32[b] = v > bands32[b] ? v * 0.8 + bands32[b] * 0.2 : v + (bands32[b] - v) * rel
        }
    }

    // MARK: transients (snare / hat), flux, centroid

    private func median64(_ h: UnsafeMutablePointer<Float>, _ n: Int) -> Float {
        guard n >= 12 else { return 0 }
        tSort.update(from: h, count: n)
        for a in 1..<n { let v = tSort[a]; var b = a - 1; while b >= 0 && tSort[b] > v { tSort[b + 1] = tSort[b]; b -= 1 }; tSort[b + 1] = v }
        return tSort[n / 2]
    }

    private func transientBands(sens: Float, kickRecent: Bool, snare: inout Float, hat: inout Float) {
        let n = AnalyzerCore.tN, h = AnalyzerCore.hop
        vDSP_vmul(frame + (AnalyzerCore.fftN - n), 1, tWin, 1, tTmp, 1, vDSP_Length(n))
        var sp = DSPSplitComplex(realp: tRe, imagp: tIm)
        tTmp.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sp, 1, vDSP_Length(n / 2)) }
        vDSP_fft_zrip(tFFT, &sp, 1, 9, FFTDirection(FFT_FORWARD))
        // log-compressed magnitude per bin (level independent): c = ln(1 + 1000 * |X| / N)
        let g: Float = 100 / Float(n)
        var total: Float = 0, sFlux: Float = 0, hFlux: Float = 0, sRise = 0, lowFlux: Float = 0, subRise: Float = 0
        var sE: Float = 0, hE: Float = 0
        for k in 1..<(n / 2) {
            let m = sqrtf(tRe[k] * tRe[k] + tIm[k] * tIm[k])
            let c = logf(1 + g * m)
            tCur[k] = c
            let d = max(0, c - tPrev[k])
            total += d
            if k <= 2 { subRise += d }
            if k >= sLo && k <= sHi { sFlux += d; sE += m; if d > 0.12 { sRise += 1 }; if k >= sLo + 5 { lowFlux += d } }
            else if k >= hLo && k <= hHi { hFlux += d; hE += m }
        }
        tPrev.update(from: tCur, count: n / 2)
        let had = tHave; tHave = true
        tWarm += 1
        if sinceSnare < Int.max / 2 { sinceSnare += h }
        if sinceHat < Int.max / 2 { sinceHat += h }
        if !had || tWarm < 12 || isSilent {
            // warm-up / silence: keep outputs quiet, still learn nothing from the first frames
            fluxOut *= 0.8
            updateCentroid()
            return
        }
        // full-band flux, slow-peak normalised
        let tf = total / Float(n / 2)
        fluxPk = max(tf, fluxPk * 0.9992, 0.06)
        let fn = min(1, tf / fluxPk)
        fluxOut = fn > fluxOut ? fn : fn + (fluxOut - fn) * 0.7
        updateCentroid()

        // the 2048-pt kick path lags a few ms behind this one, so also read the kick from the sub bins here
        let kickRecent = kickRecent || subRise > 1.6
        let tc = min(tCount, 64)
        let sens2 = 1 / sqrtf(max(0.5, sens))
        // snare: broadband (many bins rising) mid-band flux
        let nbS = Float(sHi - sLo + 1), nbH = Float(hHi - hLo + 1)
        let sMed = median64(sHist, tc), hMed = median64(hHist, tc)
        let sThr = max(0.045 * nbS * 1.0, 4.0 * sMed) * sens2
        let hThr = max(0.030 * nbH, 4.0 * hMed) * sens2
        let sFrac = Float(sRise) / nbS
        if sFlux < sThr * 0.5 { sArmed = true }
        if hFlux < hThr * 0.5 { hArmed = true }
        let midN = Float(max(1, sHi - sLo - 4))
        let sGate = sE > 2e-4, hGate = hE > 4e-4
        // snare = broadband (most bins rise), has body (500 Hz-2 kHz rises like the highs do: a hat would not, nor does a kick)
        // and has some top end (kick / 808 / plucked notes do not)
        let hPer = hFlux / nbH
        let isSnareShape = sFrac >= (kickRecent ? 0.85 : 0.6) && hPer >= 0.12 && lowFlux / midN >= 0.5 * hPer
        if sArmed && sFlux > sThr && isSnareShape && sGate && sinceSnare >= Int(0.090 * sr) {
            // coincident with a kick: only count if the mid-band energy rise is clearly its own
            if !kickRecent || sFlux > 2.5 * sThr {
                snare = min(1, 0.35 + 0.65 * min(1, (sFlux / sThr - 1) / 2.0))
                sArmed = false; sinceSnare = 0; snareCount &+= 1
            }
        }
        if hArmed && hFlux > hThr && hGate && sinceHat >= Int(0.050 * sr) {
            hat = min(1, 0.3 + 0.7 * min(1, (hFlux / hThr - 1) / 2.0))
            hArmed = false; sinceHat = 0; hatCount &+= 1
        }
        sHist[sPos] = sFlux; sPos = (sPos + 1) & 63
        hHist[hPos] = hFlux; hPos = (hPos + 1) & 63
        tCount += 1
    }

    /// Log-frequency spectral centroid from the smoothed 32 log bands, 0 (dark) ... 1 (bright).
    private func updateCentroid() {
        var num: Float = 0, den: Float = 1e-6
        for b in 0..<32 { let w = bands32[b] * bands32[b]; num += w * Float(b); den += w }
        let c = isSilent ? 0.4 : max(0, min(1, num / den / 31))
        centroidOut += (c - centroidOut) * 0.12
    }

    // MARK: pitch + peaks

    private func analysePitchAndPeaks(cutoff: Float) {
        if isSilent { havePrev = false; pitchOut = 0; peaksOut = SIMD4<Float>(); return }
        // --- bass pitch ---
        let kMin = max(1, Int((25 / binHz).rounded(.down)))
        let kMax = min(120, max(kMin + 2, Int((cutoff / binHz).rounded(.up))))
        var best = kMin
        var total: Float = 1e-12
        for k in kMin...kMax { total += p[k]; if p[k] > p[best] { best = k } }
        var hz: Float = 0
        let pk = p[best]
        let conc = (p[best] + (best > 1 ? p[best - 1] : 0) + p[best + 1]) / total
        let isMax = best == kMin ? p[best] > p[best + 1] : (p[best] >= p[best - 1] && p[best] >= p[best + 1])
        if pk > 1e-6 && conc > 0.55 && isMax {
            // phase vocoder frequency from consecutive hops
            var f: Float = Float(best) * binHz
            if havePrev {
                let r = re[best], i = im[best]
                let pr = prevRe[best], pi = prevIm[best]
                let dphi = atan2f(i, r) - atan2f(pi, pr)
                let expected = 2 * Float.pi * Float(best) * Float(AnalyzerCore.hop) / Float(AnalyzerCore.fftN)
                var dev = dphi - expected
                dev -= 2 * Float.pi * (dev / (2 * Float.pi)).rounded()
                let deltaBins = dev * Float(AnalyzerCore.fftN) / (2 * Float.pi * Float(AnalyzerCore.hop))
                if abs(deltaBins) < 1.2 { f = (Float(best) + deltaBins) * binHz }
                else { f = parabolic(best) * binHz }
            } else { f = parabolic(best) * binHz }
            if f >= 25 && f <= cutoff * 1.15 { hz = f }
        }
        pitchOut = hz
        // store spectrum phases for next hop
        let m = min(127, AnalyzerCore.half - 1)
        prevRe.update(from: re, count: m); prevIm.update(from: im, count: m)
        havePrev = true

        // --- peaks 150..4000 Hz ---
        let pLo = max(2, Int((150 / binHz).rounded(.up))), pHi = min(AnalyzerCore.half - 2, Int((4000 / binHz).rounded(.down)))
        guard pHi > pLo + 2 else { peaksOut = SIMD4<Float>(); return }
        var b1 = -1; var v1: Float = 0
        for k in pLo...pHi where p[k] > v1 && p[k] >= p[k - 1] && p[k] > p[k + 1] { v1 = p[k]; b1 = k }
        guard b1 > 0, v1 > 1e-10 else { peaksOut = SIMD4<Float>(); return }
        let f1 = parabolic(b1) * binHz
        var b2 = -1; var v2: Float = 0
        for k in pLo...pHi where p[k] > v2 && p[k] >= p[k - 1] && p[k] > p[k + 1] {
            if abs(Float(k) * binHz - f1) >= 200 { v2 = p[k]; b2 = k }
        }
        let d1 = 10 * log10f(v1 + 1e-12)
        if d1 > peakRef { peakRef = d1 } else { peakRef -= 0.012 }
        peakRef = max(peakRef, -45)
        var out = SIMD4<Float>()
        out[0] = f1; out[1] = max(0, min(1, (d1 - (peakRef - 40)) / 40))
        if b2 > 0 {
            let f2 = parabolic(b2) * binHz
            let d2 = 10 * log10f(v2 + 1e-12)
            out[2] = f2; out[3] = max(0, min(1, (d2 - (peakRef - 40)) / 40))
        }
        peaksOut = out
    }

    /// Parabolic interpolation on dB magnitudes; returns fractional bin.
    @inline(__always) private func parabolic(_ k: Int) -> Float {
        guard k >= 1 && k + 1 < AnalyzerCore.half else { return Float(k) }
        let a = log10f(p[k - 1] + 1e-20), b = log10f(p[k] + 1e-20), c = log10f(p[k + 1] + 1e-20)
        let den = a - 2 * b + c
        if den >= -1e-9 { return Float(k) }
        let d = 0.5 * (a - c) / den
        return Float(k) + max(-0.5, min(0.5, d))
    }

    // MARK: tempo

    private func evalTempo() {
        let nowT = Double(sampleCount) / sr
        let winSec = 8.0
        // count onsets in window
        var cnt = 0
        for i in 0..<oN { let t = oTimes[(oHead - 1 - i) & 63]; if nowT - t <= winSec { cnt += 1 } }
        if cnt < 5 {
            lowConfCount += 1
            if lowConfCount >= 4 { bpmCur = 0; bpmConf = 0 }
            return
        }
        // onset-impulse envelope at 100 Hz, window ending now (linear split between bins)
        let N = 800
        envAC.update(repeating: 0, count: N)
        let t0 = nowT - winSec
        for i in 0..<oN {
            let t = oTimes[(oHead - 1 - i) & 63]
            let pos = (t - t0) * 100
            if pos < 0 || pos >= Double(N - 1) { continue }
            let k = Int(pos), fr = Float(pos - Double(k)), w = oStr[(oHead - 1 - i) & 63]
            envAC[k] += w * (1 - fr); envAC[k + 1] += w * fr
        }
        var e0: Float = 0
        vDSP_dotpr(envAC, 1, envAC, 1, &e0, vDSP_Length(N))
        guard e0 > 0 else { return }
        e0 /= Float(N)
        // autocorrelation up to lag 4 * 85.7 bins
        let maxLag = 4 * 86 + 2
        for l in 1..<maxLag where l < N - 50 {
            var d: Float = 0
            vDSP_dotpr(envAC, 1, envAC + l, 1, &d, vDSP_Length(N - l))
            acv[l] = d / Float(N - l) / e0
        }
        acv[0] = 1
        @inline(__always) func ac(_ lag: Float) -> Float {
            let k = Int(lag)
            if k + 1 >= maxLag || k < 0 { return 0 }
            let fr = lag - Float(k)
            return acv[k] * (1 - fr) + acv[k + 1] * fr
        }
        @inline(__always) func wt(_ i: Int) -> Float { i == 0 ? 1.0 : (i == 1 ? 0.85 : (i == 2 ? 0.6 : 0.8)) }
        var bestS: Float = 0, bestL: Float = 0, sumS: Float = 0, nS: Float = 0
        var L: Float = 33
        while L <= 86 {
            var s: Float = 0, ws: Float = 0
            for m in 1...4 { s += wt(m - 1) * ac(Float(m) * L); ws += wt(m - 1) }
            s /= ws
            let bpm = 6000 / L
            let prior = expf(-0.5 * powf(log2f(bpm / 115) / 1.0, 2))
            s *= (0.7 + 0.3 * prior)
            sumS += s; nS += 1
            if s > bestS { bestS = s; bestL = L }
            L += 0.25
        }
        let meanS = sumS / max(1, nS)
        let conf = max(0, min(1, (bestS - meanS) / max(bestS, 1e-6) * 1.2))
        bpmConf = conf
        guard bestL > 0, bestS > 0.12, conf > 0.45 else {
            lowConfCount += 1
            if lowConfCount >= 4 { bpmCur = 0 }
            return
        }
        // refine with least squares on onset times against grid of period T0
        var T = Double(bestL) / 100
        var anchor = 0.0
        for _ in 0..<2 {
            // anchor: the strongest onset in the last 4 s as reference
            var refT = 0.0, refS: Float = -1
            for i in 0..<oN {
                let t = oTimes[(oHead - 1 - i) & 63]
                if nowT - t <= winSec && oStr[(oHead - 1 - i) & 63] > refS { refS = oStr[(oHead - 1 - i) & 63]; refT = t }
            }
            var sn = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for i in 0..<oN {
                let t = oTimes[(oHead - 1 - i) & 63]
                if nowT - t > winSec { continue }
                let nn = ((t - refT) / T).rounded()
                let res = (t - refT) - nn * T
                if abs(res) > 0.12 * T { continue }
                sn += 1; sx += nn; sy += t; sxx += nn * nn; sxy += nn * t
            }
            let den = sn * sxx - sx * sx
            if sn >= 5 && den > 1e-9 {
                let slope = (sn * sxy - sx * sy) / den
                let icpt = (sy - slope * sx) / sn
                if slope > 0.3 && slope < 0.9 { T = slope }
                anchor = icpt + 0.0
                _ = anchor
                gridT0 = icpt
            } else { gridT0 = refT }
        }
        // express gridT0 as a recent beat time close to now (phase only depends on mod T)
        gridT = T
        let est = Float(60 / T)
        lowConfCount = 0
        if bpmCur == 0 { bpmCur = est; bpmPendingN = 0 }
        else if abs(est - bpmCur) < 0.04 * bpmCur { bpmCur = bpmCur * 0.6 + est * 0.4; bpmPendingN = 0 }
        else {
            if bpmPendingN > 0 && abs(est - bpmPending) < 0.04 * bpmPending { bpmPendingN += 1 } else { bpmPending = est; bpmPendingN = 1 }
            if bpmPendingN >= 3 { bpmCur = est; bpmPendingN = 0 }
        }
    }
}

// MARK: - Public wrapper (frozen API)

final class AudioAnalyzer: @unchecked Sendable {
    static let shared = AudioAnalyzer()

    /// Who needs the fast half-hop onset path. Clients declare demand via `setOnsetDemand`; until a client
    /// declares, its running status determines demand so stopped engines never keep the fast path alive.
    enum OnsetClient { case glow, haptics }
    private static let demand = Locked((glow: false, glowExplicit: false, haptics: false, hapticsExplicit: false))
    private static let powerWatch: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: PowerState.didChange, object: nil, queue: nil) { _ in AudioAnalyzer.refreshFastPath() }

    /// Declare whether `client` currently has a mode that reacts to single onsets (beat pulse, strobe, metronome
    /// without a tempo, haptic beat modes). On battery / Low Power Mode the fast path runs only while somebody needs it.
    static func setOnsetDemand(_ client: OnsetClient, _ needed: Bool) {
        _ = powerWatch
        demand.update {
            if client == .glow { $0.glow = needed; $0.glowExplicit = true }
            else { $0.haptics = needed; $0.hapticsExplicit = true }
        }
        refreshFastPath()
    }

    private static func refreshFastPath() {
        let d = demand.get()
        let glowNeed = d.glowExplicit ? d.glow : (GlowEngine.shared.status == .running)
        let hapticsNeed = d.hapticsExplicit ? d.haptics : (HapticEngine.shared.status == .running)
        AnalyzerCore.fastOnsetEnabled.store(!PowerState.shared.saver || glowNeed || hapticsNeed, ordering: .relaxed)
    }

    private let core = AnalyzerCore(live: true, sampleRate: 48000)
    private var lastRate: Double = 48000
    private let resetFlag = Atomic<Bool>(false)
    private let timeBits = Atomic<UInt64>(0)

    private init() {
        _ = Self.powerWatch
        Self.refreshFastPath()
    }

    /// Realtime entry point (CoreAudio IO thread). Buffers internally, runs one analysis hop per
    /// 256 samples, and publishes each frame via FeatureBus.shared.publish(_:).
    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        if resetFlag.exchange(false, ordering: .relaxed) { core.resetState() }
        if sampleRate != lastRate && sampleRate > 0 {
            lastRate = sampleRate
            core.configure(sampleRate: sampleRate)
            core.resetState()
        }
        core.process(samples, count: count)
        timeBits.store(core.avgHopMs.bitPattern, ordering: .relaxed)
    }

    /// Clear all state (AGC, onset history, BPM).
    func reset() { resetFlag.store(true, ordering: .relaxed) }

    /// Average CPU time per hop in milliseconds (diagnostics).
    var processingTimeMs: Double { Double(bitPattern: timeBits.load(ordering: .relaxed)) }

    /// Offline analysis of an audio file as fast as possible (decoded to mono). Does NOT publish to
    /// FeatureBus. `time` fields are seconds from file start. Used by `--probe-audio` and tuning.
    static func analyzeFile(_ url: URL, cutoffHz: Float = 120, sensitivity: Float = 1) throws -> [AudioFeatures] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let core = AnalyzerCore(live: false, sampleRate: fmt.sampleRate)
        core.fixedCutoff = max(40, min(400, cutoffHz))
        core.fixedSens = max(0.25, min(3, sensitivity))
        var out: [AudioFeatures] = []
        out.reserveCapacity(Int(Double(file.length) / 256) + 8)
        core.onFrame = { out.append($0) }
        let chunk: AVAudioFrameCount = 16384
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
        var mono = [Float](repeating: 0, count: Int(chunk))
        let ch = Int(fmt.channelCount)
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            if ch == 1 {
                core.process(data[0], count: n)
            } else {
                mono.withUnsafeMutableBufferPointer { m in
                    m.baseAddress!.update(from: data[0], count: n)
                    for c in 1..<ch { vDSP_vadd(m.baseAddress!, 1, data[c], 1, m.baseAddress!, 1, vDSP_Length(n)) }
                    var s = 1 / Float(ch)
                    vDSP_vsmul(m.baseAddress!, 1, &s, m.baseAddress!, 1, vDSP_Length(n))
                    core.process(m.baseAddress!, count: n)
                }
            }
        }
        return out
    }
}
