// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// TapAlign: pure maths of the "Tap along" sync calibration. Given the times the user pressed a key on the
// beat and the onsets the analyzer detected (capture time), it works out how far the delay in use is off.
import Foundation

enum TapAlign {
    /// A tap counts when a detected onset's ear time (capture time + delay) lies within this many seconds of it.
    static let window = 0.150
    static let minMatches = 8
    /// Interquartile range of the tap errors above which the taps are too uneven to trust (milliseconds).
    static let maxSpreadMs = 60.0
    /// Onsets weaker than this are ignored (hats and tails the kick detector sometimes reports).
    static let minStrength: Float = 0.25

    struct Result: Equatable, Sendable {
        var deltaMs: Double      // median (tap - ear time of the matching onset); add this to the current fine-tune
        var spreadMs: Double     // interquartile range of the errors
        var matched: Int
        var taps: Int
    }
    enum Failure: Error, Equatable, Sendable {
        case tooFewMatches(matched: Int, taps: Int)
        case tooUneven(spreadMs: Double)
    }

    /// `taps` are key-press times and `onsets` onset times, both on the host clock (capture time for onsets);
    /// `delay` is the audio-to-ear delay in use (SyncClock.delay, fine-tune included).
    static func analyze(taps: [Double], onsets: [(time: Double, strength: Float)], delay: Double) -> Swift.Result<Result, Failure> {
        let usable = onsets.filter { $0.strength >= minStrength }.map { $0.time + delay }
        var errs: [Double] = []
        for t in taps {
            var best: Double?
            for o in usable {
                let e = t - o
                if abs(e) <= window, best == nil || abs(e) < abs(best!) { best = e }
            }
            if let b = best { errs.append(b * 1000) }
        }
        guard errs.count >= minMatches else { return .failure(.tooFewMatches(matched: errs.count, taps: taps.count)) }
        errs.sort()
        func q(_ p: Double) -> Double {
            let x = p * Double(errs.count - 1), lo = Int(x.rounded(.down)), hi = min(errs.count - 1, lo + 1)
            return errs[lo] + (errs[hi] - errs[lo]) * (x - Double(lo))
        }
        let spread = q(0.75) - q(0.25)
        guard spread <= maxSpreadMs else { return .failure(.tooUneven(spreadMs: spread)) }
        return .success(Result(deltaMs: q(0.5), spreadMs: spread, matched: errs.count, taps: taps.count))
    }
}
