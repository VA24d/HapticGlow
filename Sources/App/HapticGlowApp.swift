// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow entry point: window scene, menu bar extra, commands, CLI probe.
import SwiftUI
import AppKit

/// Real process entry. Handles `--probe-audio <file>` before any UI exists.
@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe-audio") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: HapticGlow --probe-audio <file>\n".utf8))
                exit(2)
            }
            exit(probeAudio(URL(fileURLWithPath: args[i + 1])))
        }
        if args.contains("--logi-probe") { exit(LogitechBacklight.probe(test: args.contains("--test"))) }
        HapticGlowApp.main()
    }

    /// Offline analysis summary: duration, onsets/s, BPM, mean bass.
    private static func probeAudio(_ url: URL) -> Int32 {
        do {
            let frames = try AudioAnalyzer.analyzeFile(url)
            guard let last = frames.last else { print("no frames produced for \(url.lastPathComponent)"); return 1 }
            let dur = max(last.time, 0.001)
            let onsets = Double(last.onsetCount)
            let tail = frames.suffix(max(1, frames.count / 3)).map { $0.bpm }.filter { $0 > 0 }.sorted()
            let bpm = tail.isEmpty ? 0 : tail[tail.count / 2]
            let meanBass = frames.reduce(0) { $0 + Double($1.bass) } / Double(frames.count)
            print(String(format: "file: %@\nduration: %.2f s\nframes: %d\nonsets: %.0f (%.2f/s)\nbpm: %.1f\nmean bass: %.3f",
                         url.lastPathComponent, dur, frames.count, onsets, onsets / dur, bpm, meanBass))
            return 0
        } catch {
            FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
            return 1
        }
    }
}

/// Hands both keyboards back to their own settings exactly once, whichever quit path gets here first.
/// The built-in and Logitech restores run concurrently; a second caller waits for the first to finish.
/// Everything is capped at about 3 s so a stuck keyboard cannot hold up the quit.
enum QuitCoordinator {
    private static let cond = NSCondition()
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var finished = false
    private static let cap: Double = 3.0

    static func handBack() {
        let deadline = Date(timeIntervalSinceNow: cap)
        cond.lock()
        if started {
            while !finished, cond.wait(until: deadline) {}
            cond.unlock()
            return
        }
        started = true
        cond.unlock()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            BacklightDriver.shared.restore(seal: true)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            LogitechBacklight.shared.restoreForQuit()
            group.leave()
        }
        if group.wait(timeout: .now() + cap) == .timedOut {
            Log.write("[quit] hand-back did not finish within \(cap) s")
        }
        cond.lock()
        finished = true
        cond.broadcast()
        cond.unlock()
    }
}

/// One set of termination-signal sources for the whole app, installed once at launch on one serial queue.
/// Hands both keyboards back to their own settings, then re-raises the signal with the default action.
enum QuitSignals {
    private static let queue = DispatchQueue(label: "HapticGlow.quit-signals", qos: .userInteractive)
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var ran = false   // only touched on `queue`

    static func install() {
        guard sources.isEmpty else { return }
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler {
                guard !ran else { return }   // a second signal while the first is restoring
                ran = true
                GlowEngine.shared.stop(quitting: true)
                QuitCoordinator.handBack()
                signal(sig, SIG_DFL)
                raise(sig)
            }
            src.resume()
            sources.append(src)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceChoice.applyStored()
        AppModel.shared.bootstrap()
        QuitSignals.install()
        if let dir = ProcessInfo.processInfo.environment["HAPTICGLOW_SNAPSHOT_DIR"] { Snapshotter.run(dir: dir) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Stops the engines first, then hands the MX Keys back once (bounded, about 1.5 s).
        AppModel.shared.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct HapticGlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("HapticGlow", id: "main") {
            RootView()
                .frame(minWidth: 780, minHeight: 540)
        }
        .defaultSize(width: 980, height: 660)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { HapticGlowCommands() }

        MenuBarExtra(isInserted: $model.showInMenuBar) {
            MenuBarView()
                .frame(width: 300)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

struct HapticGlowCommands: Commands {
    @State private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    private func reveal(_ item: SidebarItem? = nil, cheatSheet: Bool = false) {
        if let item { model.selection = item }
        if cheatSheet { model.showCheatSheet = true }
        NSApp.activate()
        openWindow(id: "main")
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { reveal(.settings) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Control") {
            Button(model.isRunning ? "Stop" : "Start") { model.toggleRunning() }
                .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Button("Previous Glow Mode") { model.cycleGlowMode(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next Glow Mode") { model.cycleGlowMode(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Brighter Ceiling") { model.nudgeCeiling(0.05) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Dimmer Ceiling") { model.nudgeCeiling(-0.05) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(model.sound.enabled ? "Mute Key Sounds" : "Unmute Key Sounds") {
                model.setSoundsEnabled(!model.sound.enabled)
                model.showToast(model.sound.enabled ? "Key sounds on" : "Key sounds muted")
            }.keyboardShortcut("m", modifiers: .command)
            Button(model.haptic.enabled ? "Turn Haptics Off" : "Turn Haptics On") {
                model.setHapticsEnabled(!model.haptic.enabled)
                model.showToast(model.haptic.enabled ? "Haptics on" : "Haptics off")
            }.keyboardShortcut("h", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                Button(item.title) { reveal(item) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        // ⌘M is used for muting key sounds, so Minimize moves to ⌘⌥M.
        CommandGroup(replacing: .windowSize) {
            Button("Zoom") { NSApp.keyWindow?.zoom(nil) }
            Button("Minimize") { NSApp.keyWindow?.miniaturize(nil) }.keyboardShortcut("m", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { reveal(cheatSheet: true) }.keyboardShortcut("/", modifiers: .command)
        }
    }
}

/// Dev-only: with HAPTICGLOW_SNAPSHOT_DIR set, render every sidebar page, the menu bar panel and the
/// onboarding steps to PNGs (works without Screen Recording permission), then exit.
/// HAPTICGLOW_SNAPSHOT_APPEARANCE=dark|light forces the appearance; HAPTICGLOW_SNAPSHOT_TAG prefixes names.
@MainActor
enum Snapshotter {
    static func run(dir: String) {
        let env = ProcessInfo.processInfo.environment
        let tag = env["HAPTICGLOW_SNAPSHOT_TAG"] ?? env["HAPTICGLOW_SNAPSHOT_APPEARANCE"] ?? "shot"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        switch env["HAPTICGLOW_SNAPSHOT_APPEARANCE"] {
        case "dark": AppearanceChoice.dark.apply()
        case "light": AppearanceChoice.light.apply()
        default: break
        }
        AppModel.shared.showOnboarding = false
        AppModel.shared.showCheatSheet = false

        func capture(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        func png(_ name: String, _ rep: NSBitmapImageRep) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-\(name).png"))
        }
        func find(_ v: NSView, _ pred: (NSView) -> Bool) -> NSView? {
            if pred(v) { return v }
            for c in v.subviews { if let r = find(c, pred) { return r } }
            return nil
        }
        /// cacheDisplay skips the sidebar's visual-effect backed table; capture it separately and composite.
        func write(_ name: String, _ v: NSView, sidebarFrom root: NSView? = nil) {
            guard let base = capture(v) else { return }
            if let root, let table = find(root, { $0 is NSOutlineView }), let scroll = table.enclosingScrollView {
                let r = scroll.convert(scroll.bounds, to: v)
                let host = NSHostingView(rootView: SidebarView().environment(\.controlActiveState, .key).frame(width: r.width, height: v.bounds.height - r.minY + 0).background(Theme.sidebar))
                host.frame = NSRect(x: 0, y: 0, width: r.width, height: v.bounds.height)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host; win.appearance = NSApp.appearance
                host.layoutSubtreeIfNeeded()
                if let side = capture(host), let ctx = NSGraphicsContext(bitmapImageRep: base) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    side.draw(in: NSRect(x: 0, y: 0, width: r.width, height: v.bounds.height), from: .zero,
                              operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            png(name, base)
        }
        func mainWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.width > 700 } }
        func shoot(_ name: String) {
            if let w = mainWindow(), let v = w.contentView?.superview ?? w.contentView { write(name, v, sidebarFrom: v) }
        }
        func menuPanel() {
            let host = NSHostingView(rootView: MenuBarView().frame(width: 300).background(Theme.window))
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: max(size.height, 100)))
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.appearance = NSApp.appearance
            host.layoutSubtreeIfNeeded()
            write("menubar", host)
        }
        NowPlaying.shared.showSampleForSnapshot()
        if let w = mainWindow() {
            var f = w.frame; f.size.height = 1000; w.setFrame(f, display: true)
        }
        /// Full-height render of a page (the window is clamped to the screen, so long pages are cut off).
        func tall(_ item: SidebarItem) {
            let page: AnyView
            switch item {
            case .dashboard: page = AnyView(DashboardView())
            case .practice: page = AnyView(PracticeView())
            case .glow: page = AnyView(GlowView())
            case .haptics: page = AnyView(HapticsView())
            case .sounds: page = AnyView(SoundsView())
            case .audio: page = AnyView(AudioInputView())
            case .permissions: page = AnyView(PermissionsView())
            case .settings: page = AnyView(SettingsView())
            }
            let host = NSHostingView(rootView: page.frame(width: 760, height: 1700).background(Theme.window))
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 1700)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host; win.appearance = NSApp.appearance
            host.layoutSubtreeIfNeeded()
            write("tall-\(item.rawValue)", host)
        }
        var pages = SidebarItem.allCases
        var steps = [0, 1, 2]
        func finish() -> Never { fflush(stdout); exit(0) }
        func onboarding() {
            guard !steps.isEmpty else { finish() }
            OnboardingView.initialStep = steps.removeFirst()
            AppModel.shared.showOnboarding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let sheet = NSApp.windows.first(where: { $0.isVisible && $0.frame.width < 700 && $0.frame.height > 300 }),
                   let v = sheet.contentView?.superview ?? sheet.contentView {
                    write("onboarding\(OnboardingView.initialStep + 1)", v)
                }
                AppModel.shared.showOnboarding = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onboarding() }
            }
        }
        func next() {
            guard !pages.isEmpty else { menuPanel(); onboarding(); return }
            let item = pages.removeFirst()
            AppModel.shared.selection = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                shoot(item.rawValue)
                if env["HAPTICGLOW_SNAPSHOT_TALL"] != nil { tall(item) }
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() }
    }
}
