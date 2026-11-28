// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// MicSync: "Measure with microphone". Passive: whatever is already playing is compared with what the built-in
// microphone hears, so the app never makes a sound. The controller checks the route and the microphone
// permission (asked only when the button is pressed), records about 6.5 s from the built-in microphone while the
// tap ring keeps the matching digital signal, then hands both to MicDelayEstimator off the main thread. A clear
// result can be applied as this output device's fine-tune; an unclear one changes nothing.
import AVFoundation
import AppKit
import Observation

@MainActor @Observable
final class MicSync {
    static let shared = MicSync()

    struct Result: Equatable {
        var measuredMs: Double
        var reportedMs: Double
        var confidence: Double
        var deviceUID: String
        var deviceName: String
        /// Fine-tune that makes SyncClock.delay equal the measurement (before clamping to the slider range).
        var neededOffsetMs: Double
    }
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case analyzing
        case done(Result)
        case failed(String)
    }
    static let recordSeconds = 6.5
    private static let tapLeadSeconds = 0.8

    private(set) var phase: Phase = .idle
    var isBusy: Bool { phase == .preparing || phase == .recording || phase == .analyzing }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recorder: MicRecorder?

    func start() {
        guard !isBusy else { return }
        let m = AppModel.shared
        let route = OutputRoute.read()
        if route.kind.isHeadphoneLike {
            phase = .failed("The output is headphones or Bluetooth. A microphone cannot hear them, so this cannot be measured. Bluetooth delay is usually steady: use Tap along instead.")
            return
        }
        if route.kind == .airPlay {
            phase = .failed("AirPlay speakers play more than half a second late, which is beyond what this can measure. Use Tap along instead.")
            return
        }
        guard let mic = OutputRoute.builtInInputDevice() else {
            phase = .failed("This Mac has no built-in microphone to listen with.")
            return
        }
        let uid = m.outputDeviceUID, name = m.outputDeviceName, reported = m.outputLatencyMs
        let autoLatency = m.sync.auto
        phase = .preparing
        task = Task { [weak self] in
            await self?.run(mic: mic, uid: uid, name: name, reported: reported, autoLatency: autoLatency)
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        MicSyncTapRing.shared.disarm()
        recorder?.stop(); recorder = nil
        phase = .idle
    }

    func dismiss() { if !isBusy { phase = .idle } }

    /// Sets this output device's fine-tune so SyncClock.delay equals the measured delay.
    func apply() {
        guard case .done(let r) = phase else { return }
        let m = AppModel.shared
        guard m.outputDeviceUID == r.deviceUID else {
            phase = .failed("The output changed since the measurement. Measure again on \(m.outputDeviceName.isEmpty ? "the new output" : m.outputDeviceName).")
            return
        }
        m.sync.setOffset(r.neededOffsetMs, for: r.deviceUID)
        Log.write(String(format: "[sync] mic measurement applied on '%@': %.0f ms measured, fine-tune %+.0f ms", r.deviceName, r.measuredMs, r.neededOffsetMs))
        m.showToast("Sync set to \(Int(r.measuredMs.rounded())) ms for \(r.deviceName)")
        phase = .idle
    }

    // MARK: run

    private func run(mic: AudioObjectID, uid: String, name: String, reported: Double, autoLatency: Bool) async {
        // Permission, asked now and only now.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok { return fail("Microphone access was not allowed. Nothing was recorded. You can allow it in System Settings, Privacy and Security, Microphone.") }
        default:
            return fail("Microphone access is off for HapticGlow. Allow it in System Settings, Privacy and Security, Microphone, then try again.")
        }
        if Task.isCancelled { return }
        // Keep a copy of the tap's signal while the microphone records.
        let ring = MicSyncTapRing.shared
        _ = ring.arm()
        let tapFrom = ring.position, stampFrom = ring.stampMark
        try? await Task.sleep(for: .seconds(Self.tapLeadSeconds))
        if Task.isCancelled { ring.disarm(); return }
        guard ring.isReceiving else {
            ring.disarm()
            return fail("No audio is playing. Start music or a video, then measure again.")
        }
        let rec = MicRecorder(deviceID: mic)
        recorder = rec
        do { try rec.start(maxSeconds: Self.recordSeconds + 0.5) } catch {
            ring.disarm(); recorder = nil
            return fail("The microphone could not be opened (\(error)). Nothing was changed.")
        }
        phase = .recording
        try? await Task.sleep(for: .seconds(Self.recordSeconds))
        rec.stop(); ring.disarm(); recorder = nil
        if Task.isCancelled { return }
        let tapTo = ring.position
        guard let heard = rec.recording(), let tap = ring.slice(from: tapFrom, to: tapTo, stampsFrom: stampFrom) else {
            return fail("The recording did not come through. Nothing was changed.")
        }
        phase = .analyzing
        let lat = MicRecorder.inputLatencySeconds(mic).seconds
        let lead = (heard.startSeconds - lat) - tap.startSeconds
        Log.write(String(format: "[sync] mic measurement: tap %.0f Hz, mic %.0f Hz, input latency %.1f ms, lead %.3f s, mic peak %.3f",
                         tap.rate, heard.rate, lat * 1000, lead, heard.peak))
        let outcome = await Task.detached(priority: .userInitiated) {
            MicDelayEstimator.estimate(tap: tap.samples, tapRate: tap.rate, mic: heard.samples, micRate: heard.rate, micLeadSeconds: lead)
        }.value
        if Task.isCancelled { return }
        switch outcome {
        case .failure(let f, let w):
            Log.write("[sync] mic measurement refused: \(f) \(w.map { String(format: "%.1f/%.1f/%.1f", $0.gccMs, $0.envMs, $0.ratio) })")
            fail(f.message)
        case .success(let me):
            Log.write(String(format: "[sync] mic measurement %.1f ms (confidence %.2f)", me.delayMs, me.confidence))
            let base = autoLatency ? reported : 0
            phase = .done(Result(measuredMs: me.delayMs, reportedMs: reported, confidence: me.confidence, deviceUID: uid,
                                 deviceName: name.isEmpty ? "this output" : name, neededOffsetMs: me.delayMs - base))
        }
    }

    private func fail(_ msg: String) { phase = .failed(msg) }
}
