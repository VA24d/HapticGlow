// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Main window: split view, unified toolbar, detail switch, toast and sheets.
import SwiftUI

struct RootView: View {
    @State private var model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .id(model.selection)
                .transition(.opacity)
                .animation(reduceMotion ? nil : Theme.snappy, value: model.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
        }
        .navigationTitle(model.selection.title)
        .toolbar {
            ToolbarItem(placement: .automatic) { LiveReadout() }
            ToolbarItem(placement: .automatic) { GlowModeMenu() }
            ToolbarItem(placement: .primaryAction) { MasterButton() }
        }
        .toastOverlay()
        .sheet(isPresented: $model.showOnboarding) { OnboardingView() }
        .sheet(isPresented: $model.showCheatSheet) { CheatSheetView() }
        .tint(Theme.accent)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .dashboard: DashboardView()
        case .practice: PracticeView()
        case .glow: GlowView()
        case .haptics: HapticsView()
        case .sounds: SoundsView()
        case .audio: AudioInputView()
        case .wallpaper: WallpaperPage()
        case .permissions: PermissionsView()
        case .settings: SettingsView()
        }
    }
}

/// Start / Stop with a crossfading label.
struct MasterButton: View {
    @State private var model = AppModel.shared

    var body: some View {
        Button { model.toggleRunning() } label: {
            ZStack {
                if model.isRunning {
                    Label("Stop", systemImage: "stop.fill").transition(.opacity)
                } else {
                    Label("Start", systemImage: "play.fill").transition(.opacity)
                }
            }
            .animation(Theme.snappy, value: model.isRunning)
            .labelStyle(.titleAndIcon)
            .frame(minWidth: 56)
        }
        .help(model.isRunning ? "Stop all engines (⌘↩)" : "Start all engines (⌘↩)")
    }
}

/// Current glow mode as a grouped menu picker.
struct GlowModeMenu: View {
    @State private var model = AppModel.shared
    private static let groups = ["Music", "Typing", "Ambient"]

    var body: some View {
        Menu {
            ForEach(Self.groups, id: \.self) { g in
                Section(g) {
                    ForEach(GlowMode.allCases.filter { GlowModeInfo.info($0).group == g }) { m in
                        Button {
                            model.glow.mode = m
                        } label: {
                            let info = GlowModeInfo.info(m)
                            if m == model.glow.mode {
                                Label(info.title, systemImage: "checkmark")
                            } else {
                                Text(info.title)
                            }
                        }
                    }
                }
            }
        } label: {
            let info = GlowModeInfo.info(model.glow.mode)
            Label(info.title, systemImage: info.symbol).labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .help("Glow mode (⌘[ and ⌘] to cycle)")
    }
}

/// Live backlight level and key-sound latency, refreshed at 10 Hz.
struct LiveReadout: View {
    var body: some View {
        Polled(every: 0.2, read: { () -> [String] in
            let level = GlowEngine.shared.currentLevel
            let lat = KeySoundEngine.shared.lastLatencyMs
            return ["\(Int((level * 100).rounded()))%", lat > 0 ? String(format: "%.1f ms", lat) : "– ms"]
        }) { v in
            HStack(spacing: 10) {
                readout("Backlight", v[0])
                readout("Latency", v[1])
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 8)
        }
        .help("Live backlight level and key-sound latency")
    }

    private func readout(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.textTertiary)
            Text(value).foregroundStyle(Theme.textSecondary)
        }
    }
}
