// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// TapCalibrator: "Tap along" sync calibration. While music plays the user presses Space or Return on the beat
// about 16 times; the median gap between each press and the nearest detected onset (at its ear time) is the
// correction for this output device. Runs entirely on the main thread: onsets are read from the FeatureBus
// history ring by a timer, nothing touches the realtime audio path.
import AppKit
import Observation
import Synchronization

/// Set while a calibration listens. KeyMonitor then drops key events before they reach KeyBus, so the taps
/// never move the glow, fire haptics or play key sounds.
enum KeyGate {
    static let suppress = Atomic<Bool>(false)
}

@MainActor @Observable
final class TapCalibrator {
    static let shared = TapCalibrator()

    enum Phase: Equatable {
        case idle
        case listening
        case done(TapAlign.Result)
        case failed(String)
    }
    static let targetTaps = 16

    private(set) var phase: Phase = .idle
    private(set) var tapCount = 0
    /// Device the calibration started on (the result is applied to this one even if the route changes meanwhile).
    private(set) var deviceUID = ""
    private(set) var deviceName = ""

    @ObservationIgnored private var taps: [Double] = []
    @ObservationIgnored private var onsets: [(time: Double, strength: Float)] = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private var collecting = false

    var isListening: Bool { phase == .listening }

    func start() {
        stop(toIdle: false)
        let m = AppModel.shared
        deviceUID = m.outputDeviceUID; deviceName = m.outputDeviceName
        taps = []; onsets = []; tapCount = 0
        startedAt = hostNow()
        collecting = true
        phase = .listening
        KeyGate.suppress.store(NSApp.isActive, ordering: .relaxed)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(true) }
            },
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(false) }
            },
        ]
        // Consume every key press in the app window while listening (Command shortcuts still work), so a tap
        // cannot press a focused button or type into a field.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard let self else { return ev }
            if ev.modifierFlags.contains(.command) { return ev }
            nonisolated(unsafe) let e = ev
            let consumed = MainActor.assumeIsolated { self.handle(e) }
            return consumed ? nil : ev
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.write("[sync] tap-along started on '\(deviceName)'")
    }

    /// Ends the capture and judges the taps collected so far.
    func finish() {
        guard phase == .listening else { return }
        poll()
        let outcome = TapAlign.analyze(taps: taps, onsets: onsets, delay: SyncClock.shared.delay)
        stop(toIdle: false)
        switch outcome {
        case .success(let r):
            phase = .done(r)
            Log.write(String(format: "[sync] tap-along '%@': %+.0f ms (spread %.0f ms, %d of %d taps matched)",
                             deviceName, r.deltaMs, r.spreadMs, r.matched, r.taps))
        case .failure(.tooFewMatches(let n, let total)):
            phase = .failed("Only \(n) of \(total) taps landed within 150 ms of a beat. Tap on the kick drum, or run it again.")
            Log.write("[sync] tap-along rejected: \(n) of \(total) taps matched")
        case .failure(.tooUneven(let s)):
            phase = .failed(String(format: "The taps were too uneven (spread %.0f ms). Try again on a steadier part of the song.", s))
            Log.write(String(format: "[sync] tap-along rejected: spread %.0f ms", s))
        }
    }

    func cancel() { stop(toIdle: true) }

    /// Sets the device's fine-tune to the measured value.
    func apply() {
        guard case .done(let r) = phase else { return }
        let m = AppModel.shared
        let current = m.sync.offsetMs(for: deviceUID)
        m.sync.setOffset(current + r.deltaMs, for: deviceUID)
        Log.write(String(format: "[sync] fine-tune for '%@' %+.0f -> %+.0f ms", deviceName, current, m.sync.offsetMs(for: deviceUID)))
        phase = .idle
    }
    func dismiss() { phase = .idle }

    // MARK: private

    private func setActive(_ on: Bool) {
        KeyGate.suppress.store(on && phase == .listening, ordering: .relaxed)
    }

    private func stop(toIdle: Bool) {
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        collecting = false
        KeyGate.suppress.store(false, ordering: .relaxed)
        if toIdle { phase = .idle }
    }

    /// Returns true when the event is consumed.
    private func handle(_ ev: NSEvent) -> Bool {
        guard phase == .listening else { return false }
        if ev.type == .keyUp { return true }
        if ev.keyCode == 53 { cancel(); return true }                 // Escape
        guard ev.keyCode == 49 || ev.keyCode == 36 || ev.keyCode == 76 else { return true }   // Space, Return, Enter
        if ev.isARepeat || !collecting { return true }
        // NSEvent.timestamp is seconds since boot on the same clock as hostNow(); using it leaves out main-thread lag.
        let t = hostNow() - (ProcessInfo.processInfo.systemUptime - ev.timestamp)
        taps.append(t); tapCount = taps.count
        if taps.count >= Self.targetTaps {
            collecting = false
            // give the analyzer a moment to publish the last onset before judging
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
        return true
    }

    private func poll() {
        let since = onsets.last?.time ?? (startedAt - 1)
        for o in FeatureBus.shared.recentOnsets(since: since) where o.time > since { onsets.append(o) }
    }
}
