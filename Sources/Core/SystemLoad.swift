// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// System CPU load, sampled once per second while something asks for it (the heartbeat glow).
import Foundation
import Darwin

/// Total CPU usage (0...1) of all cores, smoothed, plus the heart rate it maps to.
///
/// Sampling runs on a 1 Hz background timer that exists only between `setActive(true)` and
/// `setActive(false)`. One sample reads the per-core tick counters (a single mach call, a few
/// microseconds), so the cost is negligible.
final class SystemLoad: @unchecked Sendable {
    static let shared = SystemLoad()

    /// Resting and maximum heart rate for the CPU mapping.
    static let restBPM = 50.0, maxBPM = 140.0
    /// Load at or below this reads as resting.
    static let restLoad = 0.05

    private struct State {
        var load = 0.0            // smoothed 0...1
        var prev: [UInt32] = []   // previous (busy, total) tick pair
        var hasSample = false
        var active = false
    }
    private let st = Locked(State())
    private let queue = DispatchQueue(label: "hapticglow.sysload", qos: .utility)
    private var timer: DispatchSourceTimer?       // touched on `queue`
    private var powerObserver: NSObjectProtocol?

    private init() {
        powerObserver = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, let t = self.timer else { return }
                t.schedule(deadline: .now() + 1, repeating: 1.0,
                           leeway: .milliseconds(PowerState.shared.saver ? 500 : 200))
            }
        }
    }

    /// Smoothed total CPU load 0...1 (any thread, cheap).
    var load: Double { st.get().load }

    /// Target heart rate for the current load (any thread, cheap): 50 bpm at 5 % and below, 140 bpm at 100 %,
    /// eased so the first half of the range moves a little less than the last.
    var bpm: Double { Self.bpm(forLoad: load) }

    static func bpm(forLoad l: Double) -> Double {
        let u = min(max((l - restLoad) / (1 - restLoad), 0), 1)
        let e = u * (0.35 + 0.65 * u)   // gentle convex ease: calm until the machine really works
        return restBPM + (maxBPM - restBPM) * e
    }

    /// Start or stop sampling. Idempotent and safe from any thread.
    func setActive(_ on: Bool) {
        var changed = false
        st.update { s in
            guard s.active != on else { return }
            s.active = on; changed = true
        }
        guard changed else { return }
        queue.async { [self] in
            if on {
                guard timer == nil else { return }
                st.update { $0.prev = []; $0.hasSample = false }
                sample()
                let t = DispatchSource.makeTimerSource(queue: queue)
                // Larger leeway on battery: the sample is not time critical.
                t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(PowerState.shared.saver ? 500 : 200))
                t.setEventHandler { [weak self] in self?.sample() }
                timer = t
                t.resume()
            } else {
                timer?.cancel(); timer = nil
            }
        }
    }

    /// Reads the cumulative tick counters of all cores and folds the delta into the smoothed load.
    private func sample() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let b = i * stride
            let u = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]))
            let s = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
            let n = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
            busy += u + s + n; total += u + s + n + idle
        }
        // Counters are 32-bit per core and wrap; keep them as truncated sums and diff modulo 2^32 per sample.
        let pb = UInt32(truncatingIfNeeded: busy), pt = UInt32(truncatingIfNeeded: total)
        st.update { s in
            if s.prev.count == 2 {
                let db = Double(pb &- s.prev[0]), dt = Double(pt &- s.prev[1])
                if dt > 0 {
                    let inst = min(max(db / dt, 0), 1)
                    // Fast to follow a rise a little, slow to relax: a one-pole in each direction.
                    let a = inst > s.load ? 0.5 : 0.25
                    s.load = s.hasSample ? s.load + (inst - s.load) * a : inst
                    s.hasSample = true
                }
            }
            s.prev = [pb, pt]
        }
    }
}
