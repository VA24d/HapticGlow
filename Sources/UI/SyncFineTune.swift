// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// SyncFineTune: per-output-device fine-tune slider plus the "Tap along" calibration. Used by Settings and the
// Audio Input sync card. The slider follows the current output device and switches when the route changes.
import SwiftUI

struct SyncFineTune: View {
    @State private var model = AppModel.shared
    @State private var cal = TapCalibrator.shared
    @State private var mic = MicSync.shared

    private var uid: String { model.outputDeviceUID }
    private var deviceName: String { model.outputDeviceName.isEmpty ? "this output" : model.outputDeviceName }
    private var offset: Double { model.sync.offsetMs(for: uid) }

    private var slider: Binding<Double> {
        Binding(get: { model.sync.offsetMs(for: model.outputDeviceUID) },
                set: { model.sync.setOffset($0, for: model.outputDeviceUID) })
    }

    private var scopeLine: String {
        let own = uid.isEmpty ? true : model.sync.hasOffset(for: uid)
        return own ? "Applies to \(deviceName)" : "Applies to \(deviceName) (using the default until you change it)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Fine-tune").font(Theme.Font.label)
                    Text(scopeLine).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(String(format: "%+.0f ms", offset)).font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                Button("Reset") { model.sync.resetOffset(for: uid) }
                    .disabled(uid.isEmpty ? model.sync.offsetMs == 0 : !model.sync.hasOffset(for: uid))
            }
            Slider(value: slider, in: -300...300)
            Text(hint)
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            tapAlong
            micMeasure
        }
    }

    private var hint: String {
        var s = "Later if the light leads the beat, earlier if it lags. Bluetooth headphones play audio roughly 150 to 250 ms after the Mac captures it, so light and haptics are held back to match."
        if model.outputIsDisplay {
            s += " Monitor speakers usually play audio later than macOS reports, because the monitor buffers it to match its picture. Use Tap along to measure it."
        }
        return s
    }

    @ViewBuilder private var tapAlong: some View {
        switch cal.phase {
        case .idle:
            HStack(alignment: .firstTextBaseline) {
                Text("Play music, then press Space or Return on the beat about 16 times.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Tap along") { cal.start() }.controlSize(.small)
            }
        case .listening:
            HStack {
                Text("Tap Space or Return on the beat: \(cal.tapCount) of \(TapCalibrator.targetTaps)")
                    .font(Theme.Font.label)
                Spacer()
                Button("Done") { cal.finish() }.controlSize(.small).disabled(cal.tapCount < TapAlign.minMatches)
                Button("Cancel") { cal.cancel() }.controlSize(.small)
            }
        case .done(let r):
            let next = max(-300, min(300, model.sync.offsetMs(for: cal.deviceUID) + r.deltaMs))
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "Measured %+.0f ms for %@. Fine-tune would become %+.0f ms.", r.deltaMs, cal.deviceName, next))
                    .font(Theme.Font.label)
                Text("\(r.matched) of \(r.taps) taps matched a beat, spread \(Int(r.spreadMs.rounded())) ms. People tap a little early; a result within 20 ms of zero needs no change." + (abs(r.deltaMs) > 100 ? " A correction this large can be off by a whole beat: apply it, then run Tap along again to confirm." : ""))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Apply") { cal.apply() }.controlSize(.small)
                    Button("Discard") { cal.dismiss() }.controlSize(.small)
                }
            }
        case .failed(let msg):
            HStack(alignment: .firstTextBaseline) {
                Text(msg).font(Theme.Font.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try again") { cal.start() }.controlSize(.small)
                Button("Close") { cal.dismiss() }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private var micMeasure: some View {
        switch mic.phase {
        case .idle:
            HStack(alignment: .firstTextBaseline) {
                Text("Or play music through the speakers and let the built-in microphone time it. Takes about 8 seconds, nothing is recorded to disk.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Measure with microphone") { mic.start() }.controlSize(.small).disabled(cal.isListening)
            }
        case .preparing, .recording, .analyzing:
            HStack {
                Text(mic.phase == .analyzing ? "Working out the delay..." : (mic.phase == .recording ? "Listening. Keep the music playing and the room quiet." : "Getting ready..."))
                    .font(Theme.Font.label)
                Spacer()
                ProgressView().controlSize(.small)
                Button("Cancel") { mic.cancel() }.controlSize(.small)
            }
        case .done(let r):
            VStack(alignment: .leading, spacing: 4) {
                Text("Measured \(Int(r.measuredMs.rounded())) ms (\(r.deviceName)). Reported \(Int(r.reportedMs.rounded())) ms.")
                    .font(Theme.Font.label)
                Text(abs(r.neededOffsetMs) > 300
                     ? "Applying sets Fine-tune to its limit of \(r.neededOffsetMs > 0 ? "+300" : "-300") ms, short of the measured delay."
                     : String(format: "Applying sets Fine-tune to %+.0f ms for this output.", r.neededOffsetMs))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                HStack {
                    Button("Apply") { mic.apply() }.controlSize(.small)
                    Button("Discard") { mic.dismiss() }.controlSize(.small)
                }
            }
        case .failed(let msg):
            HStack(alignment: .firstTextBaseline) {
                Text(msg).font(Theme.Font.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try again") { mic.start() }.controlSize(.small)
                Button("Close") { mic.dismiss() }.controlSize(.small)
            }
        }
    }
}
