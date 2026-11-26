// Dashboard: live keyboard + spectrum, stat tiles, engine switches, and a status banner.
import SwiftUI

struct DashboardView: View {
    @Bindable var model = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Dashboard", subtitle: "Your keyboard, trackpad and audio, live.")
                banners
                visualizerCard
                StatsRow()
                enginesRow
            }
            .pageLayout()
        }
        .background(Theme.window)
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if !model.isRunning {
            ScreenNotice(symbol: "pause.circle", title: "HapticGlow is paused",
                         message: "Nothing is reacting to audio or typing right now.",
                         actionTitle: "Start") { model.start() }
        } else if model.audioState == .needsPermission {
            ScreenNotice(symbol: "lock.shield", title: model.audioSource == .processTap ? "System Audio Recording is off" : "Screen & System Audio Recording is off",
                         message: "Grant access so the keyboard and trackpad can follow what you play.",
                         actionTitle: "Open Permissions") { model.selection = .permissions }
        } else if model.audioState == .unsupported || { if case .failed = model.audioState { return true }; return false }() {
            ScreenNotice(symbol: "exclamationmark.triangle", title: "Audio capture unavailable",
                         message: model.audioState.label,
                         actionTitle: "Open Audio Input") { model.selection = .audio }
        } else if model.audioState == .idleNoAudio || model.audioState == .starting {
            ScreenNotice(symbol: "waveform", title: "Waiting for audio",
                         message: "Play something and the glow, trackpad and spectrum will wake up.", actionTitle: nil, action: nil)
        } else if !model.hasInputMonitoring {
            ScreenNotice(symbol: "keyboard", title: "Input Monitoring is off",
                         message: "Typing-reactive glow, key sounds and ripples need it.",
                         actionTitle: "Open Permissions") { model.selection = .permissions }
        }
    }

    // MARK: Visualizer

    private var visualizerCard: some View {
        VStack(spacing: Theme.Space.m) {
            KeyboardVisualizer(style: .glow, showTrackpad: true)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack {
                Text("Spectrum").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Beat").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                BeatIndicator()
            }
            SpectrumView(height: 44)
        }
        .padding(Theme.Space.l)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    // MARK: Engines

    private var enginesRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Engines")
            HStack(spacing: Theme.Space.m) {
                EngineSwitch(title: "Keyboard Glow", symbol: "light.max", status: model.glowStatus,
                             isOn: Binding(get: { model.glow.enabled }, set: { model.setGlowEnabled($0) })) { model.selection = .glow }
                EngineSwitch(title: "Trackpad Haptics", symbol: "hand.point.up.left", status: model.hapticStatus,
                             isOn: Binding(get: { model.haptic.enabled }, set: { model.setHapticsEnabled($0) })) { model.selection = .haptics }
                EngineSwitch(title: "Key Sounds", symbol: "keyboard", status: model.soundStatus,
                             isOn: Binding(get: { model.sound.enabled }, set: { model.setSoundsEnabled($0) })) { model.selection = .sounds }
            }
        }
    }
}

/// Live stat tiles, refreshed 10x/s from engine reads (no model invalidation).
private struct StatsRow: View {
    var body: some View {
        Polled(every: 0.2, read: { () -> [Int] in
            let f = FeatureBus.shared.latest()
            let lat = KeySoundEngine.shared.lastLatencyMs
            return [Int((GlowEngine.shared.currentLevel * 100).rounded()), f.silent ? 0 : 1,
                    Int((f.bass * 100).rounded()), Int(f.bpm.rounded()), KeyBus.shared.keysPerMinute(),
                    Int((lat * 10).rounded())]
        }) { v in
            let live = v[1] == 1
            let bpm = v[3]
            let lat = Double(v[5]) / 10
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m), count: 5), spacing: Theme.Space.m) {
                StatTile(title: "Backlight", value: "\(v[0])", unit: "%")
                StatTile(title: "Bass", value: live ? "\(v[2])" : "–", unit: live ? "%" : nil)
                StatTile(title: "BPM", value: live && bpm > 0 ? "\(bpm)" : "–")
                StatTile(title: "Keys / min", value: "\(v[4])")
                StatTile(title: "Key latency", value: lat > 0 ? String(format: "%.1f", lat) : "–", unit: lat > 0 ? "ms" : nil)
            }
        }
    }
}

/// Dot that expands and fades on each detected beat.
private struct BeatIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = UIPulse.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: pulse.frame(30), paused: !pulse.awake)) { _ in
            let f = FeatureBus.shared.latest()
            let t = hostNow() - f.lastOnsetTime
            let p = f.lastOnsetTime > 0 ? max(0, min(1, t / 0.18)) : 1
            ZStack {
                Circle().fill(Theme.textTertiary.opacity(0.5)).frame(width: 8, height: 8)
                Circle().fill(Theme.glow)
                    .frame(width: 8, height: 8)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.8 * p)
                    .opacity(1 - p)
            }
            .frame(width: 16, height: 16)
        }
        .pulseConsumer()
        .accessibilityLabel("Beat indicator")
    }
}

private struct EngineSwitch: View {
    let title: String
    let symbol: String
    let status: EngineStatus
    @Binding var isOn: Bool
    var open: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    StatusDot(status: isOn ? status : .stopped, size: 6)
                    Text(isOn ? status.label : "Off").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
    }
}

/// Inline notice with an optional action. Used for empty / permission states.
struct ScreenNotice: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                Text(message).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.m)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
    }
}
