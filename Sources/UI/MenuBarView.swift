// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Menu bar panel (MenuBarExtra .window style): compact Control Center-style modules.
import SwiftUI
import AppKit

struct MenuBarView: View {
    @State private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            header
            statusModule
            NowPlayingMenuRow()
            modesModule
            brightnessModule
            togglesModule
            footer
        }
        .padding(12)
        .frame(width: 300)
        .animation(Theme.snappy, value: model.isRunning)
        .animation(Theme.snappy, value: model.glow.autoSwitch)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "light.max")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.glow)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("HapticGlow").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Toggle("Running", isOn: Binding(get: { model.isRunning }, set: { _ in model.toggleRunning() }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.horizontal, 2)
    }

    // MARK: Status

    private struct EngineSnap: Equatable {
        var mode: GlowMode
        var musicActive: Bool
    }

    private var statusModule: some View {
        Polled(every: 0.5, read: {
            let eng = GlowEngine.shared
            return EngineSnap(mode: eng.activeMode, musicActive: eng.musicActive)
        }) { eng in
            let running = model.isRunning && model.glow.enabled
            let info = GlowModeInfo.info(eng.mode)
            let prefix = !model.glow.autoActive ? "Mode" : (eng.musicActive ? "Music" : "Idle")
            HStack(spacing: 10) {
                Image(systemName: running ? info.symbol : "poweroff")
                    .font(.system(size: 12))
                    .foregroundStyle(running ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(running ? "\(prefix) · \(info.title)" : (model.isRunning ? "Glow off" : "Stopped"))
                        .font(Theme.Font.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(subline).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                MiniLevel().frame(width: 52, height: 4).opacity(running ? 1 : 0.35)
            }
        }
        .modulePadding()
        .module()
    }

    private var subline: String {
        guard model.isRunning else { return "Engines paused" }
        switch model.audioState {
        case .active: return "Listening to system audio"
        case .needsPermission: return "Needs System Audio Recording"
        default: return model.audioState.label
        }
    }

    // MARK: Modes

    private var modesModule: some View {
        let auto = Binding(get: { model.glow.autoSwitch }, set: { model.glow.autoSwitch = $0 })
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Glow").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text("Auto").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Toggle("Auto switch", isOn: auto).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Group {
                if model.glow.autoActive {
                    HStack(spacing: 8) {
                        ModeMenu(caption: "Music", mode: $model.glow.mode, groups: ["Music"])
                        ModeMenu(caption: "Idle", mode: $model.glow.idleMode, groups: ["Ambient"])
                    }
                } else {
                    ModeMenu(caption: "Mode", mode: $model.glow.mode, groups: ["Music", "Typing", "Ambient"])
                }
            }
            .padding(8)
        }
        .module()
    }

    // MARK: Brightness

    private var brightnessModule: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { model.glow.ceiling },
                                  set: { v in
                                      model.glow.ceiling = max(0.05, v)
                                      if model.glow.floor > model.glow.ceiling { model.glow.floor = model.glow.ceiling }
                                  }), in: 0.05...1)
                .controlSize(.small)
                .accessibilityLabel("Brightness ceiling")
            Image(systemName: "sun.max.fill").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .module()
    }

    // MARK: Toggles

    private var togglesModule: some View {
        HStack(spacing: 0) {
            RoundToggle(title: "Glow", symbol: "light.max",
                        isOn: Binding(get: { model.glow.enabled }, set: { model.setGlowEnabled($0) }))
            RoundToggle(title: "Haptics", symbol: "hand.tap",
                        isOn: Binding(get: { model.haptic.enabled }, set: { model.setHapticsEnabled($0) }))
            RoundToggle(title: "Sounds", symbol: "speaker.wave.2",
                        isOn: Binding(get: { model.sound.enabled }, set: { model.setSoundsEnabled($0) }))
        }
        .padding(.vertical, 10)
        .module()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.bottom, 4)
            FooterButton(title: "Open HapticGlow…", shortcut: nil) {
                NSApp.activate()
                openWindow(id: "main")
            }
            FooterButton(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Pieces

private extension View {
    /// Control Center style module surface: 12 pt continuous corners, translucent fill, hairline.
    func module() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
    func modulePadding() -> some View { padding(.horizontal, 10).padding(.vertical, 9) }
}

/// Compact grouped mode picker: caption over the current mode, chevron on the right.
private struct ModeMenu: View {
    let caption: String
    @Binding var mode: GlowMode
    let groups: [String]

    var body: some View {
        let info = GlowModeInfo.info(mode)
        Menu {
            ForEach(GlowModeSets.sections(groups, including: mode), id: \.title) { sec in
                Section(sec.title) {
                    ForEach(sec.modes) { m in
                        Button {
                            mode = m
                        } label: {
                            if m == mode { Label(GlowModeInfo.info(m).title, systemImage: "checkmark") }
                            else { Text(GlowModeInfo.info(m).title) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: info.symbol)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(caption.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(Theme.textTertiary)
                    Text(info.title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("\(caption) mode")
        .accessibilityValue(info.title)
    }
}

/// Round icon toggle with a tiny label, like a Control Center tile.
private struct RoundToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    @State private var hover = false

    var body: some View {
        Button { withAnimation(Theme.snappy) { isOn.toggle() } } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Theme.window : Theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(isOn ? Color.primary : Color.primary.opacity(hover ? 0.12 : 0.08)))
                    .overlay(Circle().strokeBorder(isOn ? Color.clear : Theme.hairline, lineWidth: 0.5))
                Text(title).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct FooterButton: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                Spacer()
                if let shortcut { Text(shortcut).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(hover ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Tiny live backlight level bar, 30 fps while the panel is on screen.
private struct MiniLevel: View {
    @State private var pulse = UIPulse.shared
    @State private var shown = false
    var body: some View {
        TimelineView(.animation(minimumInterval: pulse.frame(30), paused: !(pulse.awake && shown))) { tl in
            Canvas { ctx, size in
                _ = tl.date
                let v = CGFloat(max(0, min(1, GlowEngine.shared.currentLevel)))
                let r = CGRect(origin: .zero, size: size)
                ctx.fill(Path(roundedRect: r, cornerRadius: size.height / 2), with: .color(Theme.track))
                if v > 0.01 {
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: max(size.height, size.width * v), height: size.height),
                                  cornerRadius: size.height / 2), with: .color(Theme.glow))
                }
            }
        }
        .shownConsumer($shown)
        .accessibilityHidden(true)
    }
}
