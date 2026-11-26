// Audio Input: live capture diagnostics, band meters, and backlight diagnostics.
import SwiftUI

struct AudioInputView: View {
    @State private var model = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: "Audio Input", subtitle: "Live view of what HapticGlow hears and what it does with it.")
                    StatusChip(text: model.audioState.label, status: model.audioState.engineStatus)
                }

                AudioSourceCard()

                SyncDelayCard()

                LiveAudioBlock()

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Keyboard backlight diagnostics")
                    BacklightBlock()
                }
            }
            .pageLayout()
        }
    }
}

private struct LiveAudioBlock: View {
    /// Everything the block displays, quantised to what is visible, so unchanged ticks cost nothing.
    struct Snap: Equatable {
        var callbacks = "", rate = "", analyzer = ""
        var onset = false
        var bpm = 0
        var bands = [Int](repeating: 0, count: 5)
    }

    private static func snap() -> Snap {
        let f = FeatureBus.shared.latest()
        let tap = AppModel.shared.capture
        func q(_ v: Float) -> Int { Int((min(1, max(0, v)) * 100).rounded()) }
        return Snap(callbacks: String(format: "%.0f", tap.callbackRate),
                    rate: String(format: "%.1f", tap.sampleRate / 1000),
                    analyzer: String(format: "%.3f", AudioAnalyzer.shared.processingTimeMs),
                    onset: f.lastOnsetTime > 0 && hostNow() - f.lastOnsetTime < 0.14,
                    bpm: f.bpm > 0 ? Int(f.bpm.rounded()) : 0,
                    bands: [q(f.sub), q(f.bass), q(f.lowMid), q(f.mid), q(f.high)])
    }

    var body: some View {
        Polled(every: 0.05, read: { Self.snap() }) { s in
            content(s)
        }
    }

    private func content(_ s: Snap) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                StatTile(title: "Callbacks", value: s.callbacks, unit: "/ s")
                StatTile(title: "Sample rate", value: s.rate, unit: "kHz")
                StatTile(title: "Analyzer", value: s.analyzer, unit: "ms / hop")
            }
            Card {
                HStack {
                    SectionHeader("Bands")
                    Spacer()
                    HStack(spacing: 8) {
                        Circle().fill(s.onset ? Theme.accent : Theme.track).frame(width: 8, height: 8)
                            .animation(.easeOut(duration: 0.12), value: s.onset)
                        Text("Onset").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Text(s.bpm > 0 ? "\(s.bpm) BPM" : "– BPM")
                            .font(Theme.Font.numeral).foregroundStyle(Theme.textPrimary)
                    }
                }
                meter("Sub", "20–60 Hz", Float(s.bands[0]) / 100)
                meter("Bass", "60–160 Hz", Float(s.bands[1]) / 100)
                meter("Low mid", "160–500 Hz", Float(s.bands[2]) / 100)
                meter("Mid", "0.5–2 kHz", Float(s.bands[3]) / 100)
                meter("High", "2–16 kHz", Float(s.bands[4]) / 100)
            }
        }
    }

    private func meter(_ name: String, _ range: String, _ v: Float) -> some View {
        HStack(spacing: 10) {
            Text(name).font(Theme.Font.label).foregroundStyle(Theme.textPrimary).frame(width: 60, alignment: .leading)
            Text(range).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).frame(width: 78, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.textSecondary).frame(width: max(3, g.size.width * CGFloat(min(1, max(0, v)))))
                }
            }
            .frame(height: 5)
            Text("\(Int((min(1, max(0, v)) * 100).rounded()))")
                .font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary).frame(width: 28, alignment: .trailing)
        }
    }
}

private struct BacklightBlock: View {
    private struct Snap: Equatable {
        var available: Bool
        var suppressed: Bool
        var dimmed: Bool
        var idleDimSuspended: Bool
        var autoBrightness: Bool
        var keyboardID: UInt64
        var systemPct: Int
        var lastWrittenPct: Int
        var writes: UInt64
        var skipped: UInt64
        var avgWriteMicros: Int

        static func read() -> Snap {
            let d = BacklightDriver.shared.diagnostics()
            return Snap(available: d.available, suppressed: d.suppressed, dimmed: d.dimmed,
                        idleDimSuspended: d.idleDimSuspended, autoBrightness: d.autoBrightness,
                        keyboardID: d.keyboardID,
                        systemPct: Int((d.systemLevel * 100).rounded()),
                        lastWrittenPct: Int((d.lastWritten * 100).rounded()),
                        writes: d.writes, skipped: d.skipped,
                        avgWriteMicros: Int(d.avgWriteMicros.rounded()))
        }
    }

    var body: some View {
        Polled(every: 0.5, read: { Snap.read() }) { d in
            block(d)
        }
    }

    @ViewBuilder private func block(_ d: Snap) -> some View {
        let clear = d.available && !d.suppressed && !d.dimmed
        Card {
            HStack(spacing: 8) {
                Circle().fill(!d.available ? Theme.err : (clear ? Theme.ok : Theme.warn)).frame(width: 7, height: 7)
                Text(!d.available ? "Backlight driver unavailable"
                     : (clear ? "Full brightness path is clear" : "macOS is limiting the backlight"))
                    .font(Theme.Font.label)
                Spacer()
                Text(verbatim: "Keyboard ID \(d.keyboardID)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            Divider().opacity(0.5)
            row("Suppressed", d.suppressed ? "Yes" : "No", d.suppressed ? .warn : .ok, "macOS has switched the light off")
            row("Dimmed", d.dimmed ? "Yes" : "No", d.dimmed ? .warn : .ok, "Idle or ambient dimming active")
            row("Idle dim suspended", d.idleDimSuspended ? "Yes" : "No", d.idleDimSuspended ? .ok : .neutral, "The 5 s idle dim is held off while running")
            row("Auto brightness", d.autoBrightness ? "On" : "Off", d.autoBrightness ? .warn : .ok, "Ambient sensor control, disabled while running")
            row("System level", "\(d.systemPct)%", .neutral, "What macOS reports right now")
            row("Last written", "\(d.lastWrittenPct)%", .neutral, "Last level HapticGlow sent")
            row("Writes", "\(d.writes)  (\(d.skipped) skipped)", .neutral, "Deduplicated to 8-bit steps")
            row("Avg write", "\(d.avgWriteMicros) µs", .neutral, "Cost of one hardware write")
        }
    }

    private enum Tone { case ok, warn, neutral }

    private func row(_ name: String, _ value: String, _ tone: Tone, _ hint: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(Theme.Font.label).frame(width: 140, alignment: .leading)
            Text(hint).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(Theme.Font.numeral)
                .foregroundStyle(tone == .ok ? Theme.ok : (tone == .warn ? Theme.warn : Theme.textPrimary))
        }
    }
}

/// Capture-source picker with a one-line explanation of each backend. Shared by Audio Input and onboarding.
struct AudioSourceCard: View {
    @Bindable var model = AppModel.shared
    var compact = false

    static func blurb(_ s: AudioSource) -> String {
        switch s {
        case .processTap: return "Lowest latency. Needs System Audio Recording."
        case .screenCapture: return "Uses the screen recording API. Needs Screen & System Audio Recording."
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Audio source").font(Theme.Font.label)
                Picker("Audio source", selection: $model.audioSource) {
                    ForEach(AudioSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(Self.blurb(model.audioSource)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                if !compact {
                    Text("Both capture the Mac's output digitally, the way screen recorders do. No BlackHole, Multi-Output Device or microphone is needed, and your volume keys keep working.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Delay currently applied between hearing a beat and firing glow and haptics.
struct SyncDelayCard: View {
    @State private var model = AppModel.shared

    var body: some View {
        Polled(every: 0.5, read: { Int((SyncClock.shared.delay * 1000).rounded()) }) { ms in
            Card {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync delay").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                        Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text("\(ms) ms").font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                    Button("Adjust") { model.selection = .settings }.controlSize(.small)
                }
            }
        }
    }

    private var detail: String {
        let name = model.outputDeviceName.isEmpty ? "Output" : model.outputDeviceName
        let dev = model.sync.auto ? "\(name) reports \(Int(model.outputLatencyMs.rounded())) ms" : "Device latency off"
        let off = model.sync.offsetMs == 0 ? "" : String(format: ", fine-tune %+.0f ms", model.sync.offsetMs)
        return "Glow and haptics wait for the sound to reach your ears. " + dev + off + "."
    }
}
