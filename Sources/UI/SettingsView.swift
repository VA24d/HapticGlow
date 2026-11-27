// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Settings: startup, menu bar, appearance, sensitivity, recovery, credits.
import SwiftUI
import ServiceManagement
import AppKit

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    static let key = "appearance"

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    @MainActor static func applyStored() {
        (AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system).apply()
    }
}

struct SettingsView: View {
    @State private var model = AppModel.shared
    @State private var nowPlaying = NowPlaying.shared
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Settings")

                group("General") {
                    VStack(alignment: .leading, spacing: 8) {
                        ToggleRow(title: "Launch at login", subtitle: loginSubtitle,
                                  isOn: Binding(get: { loginOn }, set: setLogin))
                        if loginStatus == .requiresApproval {
                            HStack {
                                Spacer()
                                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            }
                        }
                    }
                    ToggleRow(title: "Show in menu bar", subtitle: "Quick controls without opening the window.",
                              isOn: $model.showInMenuBar)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Appearance").font(Theme.Font.label)
                            Text("Follow the system or force light or dark.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                        .onChange(of: appearance) { _, v in (AppearanceChoice(rawValue: v) ?? .system).apply() }
                    }
                }

                group("Audio") {
                    SliderRow(title: "Onset sensitivity", value: $model.onsetSensitivity, range: 0.25...3,
                              format: { String(format: "×%.2f", $0) },
                              help: "Higher catches softer kicks; lower ignores everything but the hardest hits.")
                }

                group("Now playing") {
                    ToggleRow(title: "Genre presets",
                              subtitle: "Shape the haptics and glow to the genre of the song in Apple Music, such as a stronger kick for hip-hop. Songs you saved always win.",
                              isOn: $nowPlaying.genrePresets)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved songs").font(Theme.Font.label)
                            Text(nowPlaying.savedSongCount == 0 ? "None yet. Use Remember for this song while one plays."
                                 : "\(nowPlaying.savedSongCount) saved on this Mac.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Forget All") { nowPlaying.forgetAll() }.disabled(nowPlaying.savedSongCount == 0)
                    }
                }

                group("Sync") {
                    ToggleRow(title: "Auto (device latency)",
                              subtitle: model.outputDeviceName.isEmpty ? "Delay light and haptics by the output device's latency."
                                  : "\(model.outputDeviceName) \u{00B7} \(Int(model.outputLatencyMs.rounded())) ms measured",
                              isOn: $model.sync.auto)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Fine-tune").font(Theme.Font.label)
                            Spacer()
                            Text(String(format: "%+.0f ms", model.sync.offsetMs)).font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                            Button("Reset") { model.sync.offsetMs = 0 }.disabled(model.sync.offsetMs == 0)
                        }
                        Slider(value: $model.sync.offsetMs, in: -300...300)
                        Text("Later if the light leads the beat, earlier if it lags. Bluetooth headphones play audio roughly 150 to 250 ms after the Mac captures it, so light and haptics are held back to match.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                group("Recovery") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore keyboard backlight").font(Theme.Font.label)
                            Text("Put brightness and auto-brightness back to how macOS had them.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Restore Now") {
                            BacklightDriver.shared.restore()
                            model.showToast("Keyboard backlight restored")
                        }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Log file").font(Theme.Font.label)
                            Text("~/Library/Logs/HapticGlow/hapticglow.log")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Welcome tour").font(Theme.Font.label)
                            Text("Replay setup, or see every shortcut.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Show Again") { model.showOnboarding = true }
                        Button("Keyboard Shortcuts") { model.showCheatSheet = true }
                    }
                }

                group("Credits", divided: false) {
                    credit("MagicKey", "XiaoSong1223", "Keyboard backlight control approach")
                    credit("nospeaker", "Cody Collier (os6)", "Trackpad haptic actuation")
                    credit("kbsim", "Thomas Lai (tplai)", "Mechanical keyboard sound samples")
                    credit("Thock", "kamillobinski", "Key sound engine ideas")
                    Text("All four are MIT licensed. Their copyright notices and license texts apply to the portions derived from them.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("About", divided: false) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("HapticGlow by Vijay A").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(appVersion).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Text("GPL-3.0-only")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
                    }
                    if let repoURL = URL(string: "https://github.com/VA24d/HapticGlow") {
                        Link("https://github.com/VA24d/HapticGlow", destination: repoURL)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    Group {
                        Text("Copyright 2026 Vijay A")
                        Text("HapticGlow comes with no warranty. See LICENSE.md and NOTICE.md in the app bundle.")
                        Text("Key sounds: kbsim by Thomas Lai (tplai), MIT")
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            .controlSize(.small)
            .pageLayout()
        }
        .onAppear { refreshLogin(clearMessage: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLogin(clearMessage: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshLogin(clearMessage: false)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    /// On while registered, including when macOS is still waiting for the user to approve it.
    private var loginOn: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    private var loginSubtitle: String {
        if let loginError { return loginError }
        if loginStatus == .requiresApproval { return "Pending: approve HapticGlow in System Settings > General > Login Items." }
        return "Start HapticGlow when you sign in."
    }

    private func refreshLogin(clearMessage: Bool) {
        loginStatus = SMAppService.mainApp.status
        if clearMessage { loginError = nil }
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered && SMAppService.mainApp.status != .notFound {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
            Log.write("login item change failed: \(error)")
        }
        refreshLogin(clearMessage: false)
    }

    private func group<C: View>(_ title: String, divided: Bool = true, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title)
            if divided { GroupCard { content() } } else { Card { content() } }
        }
    }

    private func credit(_ name: String, _ author: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(Theme.Font.label)
            Text(author).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            Text("MIT").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
        }
    }
}
