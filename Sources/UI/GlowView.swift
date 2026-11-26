// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Keyboard Glow: live preview, mode gallery, brightness and behaviour controls.
import SwiftUI

struct GlowView: View {
    @Bindable var model = AppModel.shared

    private var heartInUse: Bool {
        let g = model.glow
        return g.mode == .heartbeat || (g.autoActive && g.idleMode == .heartbeat)
    }

    /// "MX KEYS B · 8 levels · 24 ms Bluetooth, sent early" or a hint when none is connected.
    private static func logiSubtitle() -> String {
        let lb = LogitechBacklight.shared
        guard let name = lb.keyboardNames.first else {
            return "Mirrors the glow on an MX Keys keyboard over Bluetooth. None connected."
        }
        return "\(name) · \(lb.levelCount) levels · \(Int((lb.leadSeconds * 1000).rounded())) ms Bluetooth delay, sent early to stay in sync."
    }

    /// Live CPU text only while the engine runs with the glow on; otherwise the fixed text.
    private static func heartSubtitle() -> String {
        let m = AppModel.shared
        guard m.glow.heartFollowsCPU else { return "Heartbeat keeps a steady rate." }
        guard m.isRunning && m.glow.enabled else {
            return "Heartbeat speeds up with the processor while the glow is running."
        }
        let l = SystemLoad.shared
        return "Heartbeat speeds up with the processor. Now \(Int((l.load * 100).rounded())) % load, \(Int(l.bpm.rounded())) bpm."
    }

    private let groups = ["Music", "Typing", "Ambient"]
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: Theme.Space.m, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Keyboard Glow", subtitle: "Drive the real keyboard backlight from music, typing or a calm ambient pattern.")
                livePreview
                autoSection
                ForEach(groups, id: \.self) { g in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(g)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.m) {
                            ForEach(GlowMode.allCases.filter { GlowModeInfo.info($0).group == g }) { mode in
                                let role = role(of: mode)
                                ModeCard(mode: mode, selected: role != nil, badge: model.glow.autoActive ? role : nil) {
                                    withAnimation(Theme.snappy) { choose(mode) }
                                }
                            }
                        }
                    }
                }
                controls
            }
            .pageLayout()
        }
        .background(Theme.window)
    }

    // MARK: Auto switching

    /// "Music" / "Idle" when `mode` fills that role (auto on), "Mode" when it is the only mode, else nil.
    private func role(of mode: GlowMode) -> String? {
        let g = model.glow
        if !g.autoActive { return g.mode == mode ? "Mode" : nil }
        if g.mode == mode { return "Music" }
        if g.idleMode == mode { return "Idle" }
        return nil
    }

    /// With auto on, ambient cards pick the idle mode and the rest pick the music mode.
    private func choose(_ mode: GlowMode) {
        if model.glow.autoActive && GlowModeInfo.info(mode).group == "Ambient" { model.glow.idleMode = mode }
        else { model.glow.mode = mode }
    }

    private var autoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Auto")
            Card {
                ToggleRow(title: "Switch automatically",
                          subtitle: "Show the music mode while music plays and the idle mode the rest of the time.",
                          isOn: $model.glow.autoSwitch)
                if model.glow.autoSwitch {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    HStack(spacing: Theme.Space.xl) {
                        modePickerRow("Music mode", selection: $model.glow.mode, groups: ["Music"])
                        modePickerRow("Idle mode", selection: $model.glow.idleMode, groups: ["Ambient"])
                    }
                    Text("Music is detected from system audio after about 1.5 s of sound and ends after 4 s of silence. The two modes crossfade over about a second. With Idle set to Off, the keyboard returns to your own brightness between songs.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func modePickerRow(_ title: String, selection: Binding<GlowMode>, groups: [String]) -> some View {
        HStack {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                ForEach(GlowModeSets.sections(groups, including: selection.wrappedValue), id: \.title) { sec in
                    Section(sec.title) {
                        ForEach(sec.modes) { m in Text(GlowModeInfo.info(m).title).tag(m) }
                    }
                }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Live preview + true level

    private var livePreview: some View {
        Card {
            KeyboardVisualizer(style: .glow)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack(spacing: Theme.Space.m) {
                Text("Backlight").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                LevelBar()
                    .frame(height: 6)
                LevelReadout()
                Button("Flash test") { GlowEngine.shared.flash(times: 3) }
                    .controlSize(.small)
                    .help("Blink the real keyboard backlight three times")
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        let ceiling = Binding<Float>(
            get: { model.glow.ceiling },
            set: { v in
                model.glow.ceiling = max(0.05, v)
                if model.glow.floor > model.glow.ceiling { model.glow.floor = model.glow.ceiling }
            })
        let floor = Binding<Float>(
            get: { model.glow.floor },
            set: { v in model.glow.floor = min(v, model.glow.ceiling) })
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Brightness")
            Card {
                Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.l) {
                    GridRow {
                        SliderRow(title: "Peak brightness", value: ceiling, range: 0.05...1,
                                  help: "Highest backlight level. 100% is full hardware brightness.")
                        SliderRow(title: "Floor", value: floor, range: 0...1,
                                  help: "Lowest level between flashes.")
                    }
                    GridRow {
                        SliderRow(title: "Speed", value: $model.glow.speed, range: 0.25...4,
                                  format: { String(format: "%.2f×", $0) }, help: "Pace of ambient patterns, decay length of reactive ones.")
                        SliderRow(title: "Sensitivity", value: $model.glow.sensitivity, range: 0.25...3,
                                  format: { String(format: "%.2f×", $0) }, help: "How readily music and typing trigger the light.")
                    }
                    if model.glow.mode == .steady || model.glow.mode == .sleep {
                        GridRow {
                            if model.glow.mode == .steady {
                                SliderRow(title: "Steady level", value: $model.glow.steadyLevel, range: 0...1)
                            }
                            if model.glow.mode == .sleep {
                                SliderRow(title: "Fade-out time", value: $model.glow.sleepMinutes, range: 1...60, step: 1,
                                          format: { "\(Int($0)) min" }, help: "Breathing slows and fades to off over this time.")
                            }
                        }
                    }
                }
            }
            SectionHeader("Behaviour").padding(.top, Theme.Space.s)
            Card {
                if heartInUse {
                    PolledSubtitleToggle(title: "Follow CPU load", subtitle: Self.heartSubtitle, isOn: $model.glow.heartFollowsCPU)
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
                ToggleRow(title: "Key flash", subtitle: "Add a quick flash on every key press, on top of any mode.", isOn: $model.glow.keyFlash)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ToggleRow(title: "Keep keyboard lit",
                          subtitle: "macOS dims the keyboard 5 s after you stop typing; HapticGlow keeps it lit while running.",
                          isOn: $model.glow.keepAwake)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                PolledSubtitleToggle(title: "Logitech keyboard", subtitle: Self.logiSubtitle, isOn: $model.glow.logitech)
            }
        }
    }
}

/// Toggle row whose subtitle is re-read on a timer; only the subtitle text is re-evaluated.
private struct PolledSubtitleToggle: View {
    let title: String
    let subtitle: () -> String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                Polled(every: 2, read: subtitle) { text in
                    Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Horizontal bar showing the true hardware backlight level.
/// Drawn in a Canvas that reads the level on every frame: a plain view body that reads a
/// non-observable value is not re-evaluated by TimelineView, which left the bar frozen at its minimum.
private struct LevelBar: View {
    @State private var pulse = UIPulse.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: pulse.frame(60), paused: !pulse.awake)) { tl in
            Canvas { ctx, size in
                _ = tl.date
                let v = CGFloat(max(0, min(1, GlowEngine.shared.currentLevel)))
                let r = CGRect(origin: .zero, size: size)
                ctx.fill(Path(roundedRect: r, cornerRadius: size.height / 2), with: .color(Theme.track))
                if v > 0.002 {
                    let w = max(size.height, size.width * v)
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: size.height / 2),
                             with: .color(Theme.glow))
                }
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), cornerRadius: size.height / 2),
                           with: .color(Theme.hairline), lineWidth: 0.5)
            }
        }
        .pulseConsumer()
        .accessibilityHidden(true)
    }
}

private struct LevelReadout: View {
    var body: some View {
        Polled(every: 0.1, read: { Int((GlowEngine.shared.currentLevel * 100).rounded()) }) { pct in
            Text(verbatim: "\(pct)%")
                .font(Theme.Font.numeral)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
