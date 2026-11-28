// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// MicDelayEstimator: pure signal processing for "Measure with microphone". Given what the process tap captured
// (the digital signal sent to the output) and what the built-in microphone heard a moment later, it finds the
// delay between them. Two independent methods run on overlapping windows: GCC-PHAT (sharp, robust to room
// reverberation) and an onset-envelope cross-correlation (coarse cross-check). A window counts only when both
// agree. No audio API, no UI, no allocation limits: runs off the main thread on copies of the recordings.
import Accelerate
import Foundation

enum MicDelayEstimator {
    /// Internal analysis rate.
    static let fs = 16000.0
    static let maxLagSeconds = 0.6
    static let bandLow = 150.0, bandHigh = 4000.0
    static let agreeMs = 8.0
    static let minPeakRatio: Float = 1.6
    /// Band-limited RMS (full scale 1.0) the tap must reach to count as "audio playing".
    static let minTapRMS: Float = 5e-4
    /// Band-limited RMS at the microphone below which the sound is too quiet to measure.
    static let minMicRMS: Float = 4e-4

    struct Window: Sendable {
        var gccMs: Double, envMs: Double, ratio: Float, envRatio: Float, valid: Bool
    }
    struct Measurement: Sendable {
        /// Delay from the tap's capture to the sound reaching the microphone, in milliseconds.
        var delayMs: Double
        /// 0...1, from how many windows were valid and how clear their peaks were.
        var confidence: Double
        var windows: [Window]
    }
    enum Failure: Sendable, Equatable {
        case noAudio       // the tap carried (almost) nothing
        case tooQuiet      // the microphone heard too little
        case noisy         // no clear peak: room noise, or the sound does not reach the microphone
        case inconsistent  // windows or methods disagreed
        case tooShort

        var message: String {
            switch self {
            case .noAudio: "No audio is playing. Start music or a video, then measure again."
            case .tooQuiet: "Too quiet: the microphone barely heard it. Raise the volume a little and try again."
            case .noisy: "Too much room noise, or the sound does not reach the microphone. Nothing was changed."
            case .inconsistent: "The measurements disagreed with each other. Try again with steady music playing. Nothing was changed."
            case .tooShort: "The recording was too short to measure. Nothing was changed."
            }
        }
    }
    enum Outcome: Sendable {
        case success(Measurement)
        case failure(Failure, [Window])
    }

    // MARK: entry

    /// `tap` and `mic` are mono recordings at their own rates. `micLeadSeconds` is how much later the microphone
    /// recording's first sample was heard than the tap's first sample was captured, with the microphone's input
    /// latency already removed (it may be negative).
    static func estimate(tap: [Float], tapRate: Double, mic: [Float], micRate: Double, micLeadSeconds: Double) -> Outcome {
        guard tapRate > 8000, micRate > 8000, tap.count > Int(tapRate), mic.count > Int(micRate * 2) else { return .failure(.tooShort, []) }
        let x = resample(tap, from: tapRate)
        let y = resample(mic, from: micRate)
        let d0 = Int((micLeadSeconds * fs).rounded())
        // Absolute-indexed array: y2[n] = y[n - d0] (the microphone recording laid on the tap's timeline).
        var y2 = [Float](repeating: 0, count: max(x.count, y.count + max(d0, 0)))
        for i in 0..<y.count { let n = i + d0; if n >= 0 && n < y2.count { y2[n] = y[i] } }
        let M = Int(maxLagSeconds * fs)
        let micStart = max(0, d0)
        let micEnd = min(y2.count, d0 + y.count)
        let region = micEnd - micStart
        guard region > Int(1.5 * fs) else { return .failure(.tooShort, []) }
        let W = min(Int(3.5 * fs), Int(Double(region) * 0.7))
        let nWin = 3
        var windows: [Window] = []
        var tapQuiet = 0, micQuiet = 0
        for k in 0..<nWin {
            let a = micStart + (region - W) * k / (nWin - 1)
            let lo = a - M, hi = a + W
            var xs = [Float](repeating: 0, count: hi - lo), ys = xs
            for n in lo..<hi {
                if n >= 0 && n < x.count { xs[n - lo] = x[n] }
                if n >= micStart && n < micEnd && n < y2.count { ys[n - lo] = y2[n] }
            }
            if let w = analyzeWindow(xs, ys, tapQuiet: &tapQuiet, micQuiet: &micQuiet) { windows.append(w) }
        }
        if tapQuiet >= 2 { return .failure(.noAudio, windows) }
        if micQuiet >= 2 { return .failure(.tooQuiet, windows) }
        let good = windows.filter { $0.valid }
        if good.count < 2 {
            let clear = windows.filter { $0.ratio >= minPeakRatio }
            return .failure(clear.count >= 2 ? .inconsistent : .noisy, windows)
        }
        let ms = good.map { $0.gccMs }.sorted()
        if ms.last! - ms.first! > agreeMs { return .failure(.inconsistent, windows) }
        let median = ms[ms.count / 2]
        let clarity = good.map { Double(min(1, max(0, ($0.ratio - 1) / 2))) }.reduce(0, +) / Double(good.count)
        let conf = Double(good.count) / Double(nWin) * clarity
        return .success(Measurement(delayMs: median, confidence: conf, windows: windows))
    }

    // MARK: one window

    private static func analyzeWindow(_ xs: [Float], _ ys: [Float], tapQuiet: inout Int, micQuiet: inout Int) -> Window? {
        let len = xs.count
        var n = 1; while n < 2 * len { n <<= 1 }
        let plan = FFTPlan.get(n)
        var xr = [Float](repeating: 0, count: n), xi = xr, yr = xr, yi = xr
        // Hann window over the segment, remove DC.
        var hann = [Float](repeating: 0, count: len)
        vDSP_hann_window(&hann, vDSP_Length(len), Int32(vDSP_HANN_DENORM))
        let mx = vDSP.mean(xs), my = vDSP.mean(ys)
        for i in 0..<len { xr[i] = (xs[i] - mx) * hann[i]; yr[i] = (ys[i] - my) * hann[i] }
        plan.forward(&xr, &xi); plan.forward(&yr, &yi)
        let mask = bandMask(n)
        // Cross spectrum G = Y * conj(X), band-limited.
        var gr = [Float](repeating: 0, count: n), gi = gr
        var magSum: Double = 0, cnt = 0
        for k in 0..<n where mask[k] > 0 {
            let r = yr[k] * xr[k] + yi[k] * xi[k]
            let i = yi[k] * xr[k] - yr[k] * xi[k]
            gr[k] = r; gi[k] = i
            magSum += Double(hypotf(r, i)); cnt += 1
        }
        guard cnt > 0 else { return nil }
        let meanMag = Float(magSum / Double(cnt))
        // Band-limited levels (Parseval over the masked half spectrum, Hann gain compensated).
        let tapRMS = bandRMS(xr, xi, mask, n, len), micRMS = bandRMS(yr, yi, mask, n, len)
        if tapRMS < minTapRMS { tapQuiet += 1 }
        if micRMS < minMicRMS { micQuiet += 1 }
        // PHAT with a soft floor so near-empty bins do not get amplified into noise.
        var pr = [Float](repeating: 0, count: n), pi = pr
        for k in 0..<n where mask[k] > 0 {
            let m = hypotf(gr[k], gi[k]) + 0.02 * meanMag + 1e-20
            pr[k] = gr[k] / m * mask[k]; pi[k] = gi[k] / m * mask[k]
        }
        plan.inverse(&pr, &pi)
        let maxLag = Int(maxLagSeconds * fs)
        let (gccLag, ratio) = pickPeak(Array(pr[0...maxLag]), exclude: Int(0.02 * fs))
        let gccMs = gccLag / fs * 1000
        // Envelope cross-check.
        let (envLag, envRatio) = envelopeLag(xr: xr, xi: xi, yr: yr, yi: yi, mask: mask, n: n, plan: plan, len: len)
        let envMs = envLag
        let valid = ratio >= minPeakRatio && abs(envMs - gccMs) < agreeMs && tapRMS >= minTapRMS && micRMS >= minMicRMS
        return Window(gccMs: gccMs, envMs: envMs, ratio: ratio, envRatio: envRatio, valid: valid)
    }

    /// Envelope lag in ms (1 ms resolution) of y behind x, with its peak ratio.
    private static func envelopeLag(xr: [Float], xi: [Float], yr: [Float], yi: [Float], mask: [Float], n: Int,
                                    plan: FFTPlan, len: Int) -> (Double, Float) {
        func env(_ re: [Float], _ im: [Float]) -> [Float] {
            var r = re, i = im
            for k in 0..<n { r[k] *= mask[k]; i[k] *= mask[k] }
            plan.inverse(&r, &i)
            // Block-mean of |signal| over 16 samples = 1 kHz envelope, then positive flux of a compressed envelope.
            let bs = Int(fs / 1000), cntB = len / bs
            var e = [Float](repeating: 0, count: cntB)
            for b in 0..<cntB {
                var s: Float = 0
                for j in 0..<bs { s += abs(r[b * bs + j]) }
                e[b] = sqrtf(s / Float(bs))
            }
            // Smooth over 6 ms, flux over 12 ms (rise of the envelope).
            var sm = [Float](repeating: 0, count: cntB)
            let h = 3
            for b in 0..<cntB {
                var s: Float = 0, c: Float = 0
                for j in max(0, b - h)...min(cntB - 1, b + h) { s += e[j]; c += 1 }
                sm[b] = s / c
            }
            var flux = [Float](repeating: 0, count: cntB)
            for b in 12..<cntB { flux[b] = max(0, sm[b] - sm[b - 12]) }
            return flux
        }
        let ex = env(xr, xi), ey = env(yr, yi)
        let m = min(ex.count, ey.count)
        var N = 1; while N < 2 * m { N <<= 1 }
        let p = FFTPlan.get(N)
        var ar = [Float](repeating: 0, count: N), ai = ar, br = ar, bi = ar
        let mex = vDSP.mean(Array(ex[0..<m])), mey = vDSP.mean(Array(ey[0..<m]))
        for i in 0..<m { ar[i] = ex[i] - mex; br[i] = ey[i] - mey }
        p.forward(&ar, &ai); p.forward(&br, &bi)
        var cr = [Float](repeating: 0, count: N), ci = cr
        for k in 0..<N { cr[k] = br[k] * ar[k] + bi[k] * ai[k]; ci[k] = bi[k] * ar[k] - br[k] * ai[k] }
        p.inverse(&cr, &ci)
        let maxLag = min(Int(maxLagSeconds * 1000), m - 1)
        let (lag, ratio) = pickPeak(Array(cr[0...maxLag]), exclude: 20)
        return (lag, ratio)
    }

    /// Frequency-domain band mask over a full-length FFT (bins above n/2 mirror the lower half).
    private static func bandMask(_ n: Int) -> [Float] {
        var m = [Float](repeating: 0, count: n)
        for k in 0...(n / 2) {
            let f = Double(k) * fs / Double(n)
            var w: Double
            if f < bandLow - 50 || f > bandHigh + 500 { w = 0 }
            else if f < bandLow { w = 0.5 - 0.5 * cos(Double.pi * (f - (bandLow - 50)) / 50) }
            else if f <= bandHigh { w = 1 }
            else { w = 0.5 + 0.5 * cos(Double.pi * (f - bandHigh) / 500) }
            m[k] = Float(w)
            if k > 0 && k < n / 2 { m[n - k] = Float(w) }
        }
        return m
    }

    private static func bandRMS(_ re: [Float], _ im: [Float], _ mask: [Float], _ n: Int, _ len: Int) -> Float {
        var e: Double = 0
        for k in 0..<n where mask[k] > 0 { e += Double(mask[k] * mask[k]) * Double(re[k] * re[k] + im[k] * im[k]) }
        // Parseval: sum|x|^2 = (1/n) sum|X|^2; Hann window power is 3/8.
        let power = e / Double(n) / Double(len) / 0.375
        return Float(power.squareRoot())
    }

    /// Highest peak of |r| and its ratio to the best value at least `exclude` bins away. Parabolic refinement.
    private static func pickPeak(_ r: [Float], exclude: Int) -> (Double, Float) {
        var bi = 0; var bv: Float = 0
        for i in 0..<r.count where abs(r[i]) > bv { bv = abs(r[i]); bi = i }
        var sv: Float = 1e-12
        for i in 0..<r.count where abs(i - bi) > exclude && abs(r[i]) > sv { sv = abs(r[i]) }
        var lag = Double(bi)
        if bi > 0 && bi < r.count - 1 {
            let a = r[bi - 1], b = r[bi], c = r[bi + 1]
            let d = a - 2 * b + c
            if d != 0 { lag += Double(0.5 * (a - c) / d) }
        }
        return (lag, bv / sv)
    }

    // MARK: resampling

    /// Windowed-sinc resampler to `fs` (cutoff 0.4 * fs), enough for a band-limited analysis path.
    static func resample(_ s: [Float], from rate: Double) -> [Float] {
        if s.isEmpty { return [] }
        let outN = Int(Double(s.count) / rate * fs)
        var out = [Float](repeating: 0, count: outN)
        let ratio = rate / fs
        let cutoff = min(1.0, fs / rate) * 0.8   // fraction of the input Nyquist
        let half = 24
        s.withUnsafeBufferPointer { sp in
            for o in 0..<outN {
                let pos = Double(o) * ratio
                let c = Int(pos.rounded(.down))
                var acc: Float = 0
                for j in (c - half + 1)...(c + half) where j >= 0 && j < sp.count {
                    let d = Double(j) - pos
                    let t = d * cutoff
                    let sinc = abs(t) < 1e-9 ? 1.0 : sin(Double.pi * t) / (Double.pi * t)
                    let w = 0.5 + 0.5 * cos(Double.pi * d / Double(half))
                    acc += sp[j] * Float(sinc * w * cutoff)
                }
                out[o] = acc
            }
        }
        return out
    }
}

/// Cached radix-2 complex FFT plans (split real/imag arrays).
final class FFTPlan: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [Int: FFTPlan] = [:]
    static func get(_ n: Int) -> FFTPlan {
        lock.lock(); defer { lock.unlock() }
        if let p = plans[n] { return p }
        let p = FFTPlan(n); plans[n] = p; return p
    }
    let n: Int, log2n: vDSP_Length
    private let setup: FFTSetup
    private init(_ n: Int) {
        self.n = n; log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }
    func forward(_ re: inout [Float], _ im: inout [Float]) { run(&re, &im, FFTDirection(kFFTDirection_Forward)) }
    func inverse(_ re: inout [Float], _ im: inout [Float]) {
        run(&re, &im, FFTDirection(kFFTDirection_Inverse))
        var s = 1 / Float(n)
        vDSP_vsmul(re, 1, &s, &re, 1, vDSP_Length(n)); vDSP_vsmul(im, 1, &s, &im, 1, vDSP_Length(n))
    }
    private func run(_ re: inout [Float], _ im: inout [Float], _ dir: FFTDirection) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &sc, 1, log2n, dir)
            }
        }
    }
}
