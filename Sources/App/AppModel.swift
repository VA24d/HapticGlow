// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// AppModel — the single observable the UI binds to. Owns persistence and engine wiring.
// Stable interface between the engines and the UI: the property and method names below are what the views use.
import Foundation
import AppKit
import Observation

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, practice, glow, haptics, sounds, audio, permissions, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .practice: return "Typing Practice"
        case .glow: return "Keyboard Glow"
        case .haptics: return "Trackpad Haptics"
        case .sounds: return "Key Sounds"
        case .audio: return "Audio Input"
        case .permissions: return "Permissions"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .practice: return "text.cursor"
        case .glow: return "light.max"
        case .haptics: return "hand.point.up.left"
        case .sounds: return "keyboard"
        case .audio: return "waveform"
        case .permissions: return "lock.shield"
        case .settings: return "gearshape"
        }
    }
    var section: String {
        switch self {
        case .dashboard, .practice: return "Live"
        case .glow, .haptics, .sounds, .audio: return "Engines"
        case .permissions, .settings: return "App"
        }
    }
}

enum PrivacyPane {
    case audioCapture, inputMonitoring, screenRecording
    var url: URL {
        switch self {
        case .audioCapture: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        case .inputMonitoring: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Persisted settings (each change is pushed to its engine immediately)
    var glow: GlowConfig { didSet { if glow != oldValue { NowPlaying.shared.glowEdited(from: oldValue); GlowEngine.shared.update(glow); save() } } }
    var haptic: HapticConfig { didSet { if haptic != oldValue { NowPlaying.shared.hapticEdited(from: oldValue); pushHaptic(); save(); syncHapticRunState() } } }
    var sound: SoundConfig { didSet { if sound != oldValue { KeySoundEngine.shared.update(sound); save() } } }
    var onsetSensitivity: Float { didSet { FeatureBus.shared.sensitivity = onsetSensitivity; save() } }
    /// Audio-to-ear sync. Pushed to SyncClock; OutputLatency supplies the measured device latency.
    var sync: SyncConfig { didSet { if sync != oldValue { pushSync(); save() } } }
    /// Live: current output device and its measured latency (updated by OutputLatency on the main actor).
    var outputDeviceName: String = ""
    var outputLatencyMs: Double = 0
    /// UID of the current output device; picks which fine-tune applies (see SyncConfig.deviceOffsets).
    var outputDeviceUID: String = "" { didSet { if oldValue != outputDeviceUID { pushSync() } } }
    /// Current output is display audio (DisplayPort / HDMI / Thunderbolt display).
    var outputIsDisplay = false
    var showInMenuBar: Bool = true { didSet { save(); updateMenuBarPolling() } }
    /// System-audio capture backend. Switching while running restarts capture.
    var audioSource: AudioSource = .processTap {
        didSet {
            guard audioSource != oldValue else { return }
            save()
            if isRunning {
                (oldValue == .processTap ? SystemAudioTap.shared as AudioCapture : ScreenCaptureAudio.shared).stop()
                AudioAnalyzer.shared.reset()
                capture.start()
                refreshStatuses()
            }
        }
    }
    /// The active capture backend (UI reads callbackRate / sampleRate from it).
    var capture: AudioCapture { audioSource == .processTap ? SystemAudioTap.shared : ScreenCaptureAudio.shared }
    var hasCompletedOnboarding: Bool { didSet { save() } }

    // MARK: Live state (not persisted)
    var isRunning = false
    var audioState: AudioInputState = .inactive
    var keyStatus: EngineStatus = .stopped
    var glowStatus: EngineStatus = .stopped
    var hapticStatus: EngineStatus = .stopped
    /// What Auto sees: the playing source and the mode it picked (HapticsView shows it).
    var autoStatus = AutoSourceStatus()
    var soundStatus: EngineStatus = .stopped
    var hasInputMonitoring = false
    var selection: SidebarItem = .dashboard
    var showOnboarding = false
    var showCheatSheet = false
    var toast: String?

    // MARK: Menu bar icon (polled at 1 Hz, written only when it changes)
    var menuBarSymbol = "light.min"
    private var menuBarTimer: Timer?

    func updateMenuBarPolling() {
        if showInMenuBar { startMenuBarPolling() } else { menuBarTimer?.invalidate(); menuBarTimer = nil }
    }

    func startMenuBarPolling() {
        guard showInMenuBar, menuBarTimer == nil else { return }
        refreshMenuBarSymbol()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuBarSymbol() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        menuBarTimer = t
    }

    private func refreshMenuBarSymbol() {
        let s: String
        if !isRunning || !glow.enabled { s = "light.min" }
        else if glow.autoSwitch && !GlowEngine.shared.musicActive { s = GlowEngine.shared.activeMode == .off ? "light.min" : "moon.zzz" }
        else { s = "light.max" }
        if s != menuBarSymbol { menuBarSymbol = s }
    }

    var packs: [SoundPack] { KeySoundEngine.shared.packs }

    private let defaults = UserDefaults.standard
    private var toastTask: Task<Void, Never>?

    private init() {
        let dec = JSONDecoder()
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let d = UserDefaults.standard.data(forKey: key), let v = try? dec.decode(T.self, from: d) else { return fallback }
            return v
        }
        glow = load("glow.v2", GlowConfig())
        haptic = load("haptic.v2", HapticConfig())
        sound = load("sound.v2", SoundConfig())
        sync = load("sync.v1", SyncConfig())
        onsetSensitivity = UserDefaults.standard.object(forKey: "onsetSensitivity") as? Float ?? 1.0
        showInMenuBar = UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool ?? true
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarded.v2")
        audioSource = AudioSource(rawValue: UserDefaults.standard.string(forKey: "audioSource") ?? "") ?? .processTap
        showOnboarding = !hasCompletedOnboarding
    }

    private func save() {
        let enc = JSONEncoder()
        // While a song's tuning is layered on, the user's normal settings are what gets saved.
        let (savedHaptic, savedGlow) = NowPlaying.shared.persisted(haptic: haptic, glow: glow)
        if let d = try? enc.encode(savedGlow) { defaults.set(d, forKey: "glow.v2") }
        if let d = try? enc.encode(savedHaptic) { defaults.set(d, forKey: "haptic.v2") }
        if let d = try? enc.encode(sound) { defaults.set(d, forKey: "sound.v2") }
        if let d = try? enc.encode(sync) { defaults.set(d, forKey: "sync.v1") }
        defaults.set(onsetSensitivity, forKey: "onsetSensitivity")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(hasCompletedOnboarding, forKey: "onboarded.v2")
        defaults.set(audioSource.rawValue, forKey: "audioSource")
    }

    /// Auto source detection runs only while it can matter: haptics on, Auto chosen with music/movie, app running.
    func syncAutoSource() {
        let on = isRunning && !Self.silentLaunch && haptic.enabled && haptic.autoSource && (haptic.mode == .music || haptic.mode == .movie)
        AudioSourceMonitor.shared.onStatus = { st in Task { @MainActor in if AppModel.shared.autoStatus != st { AppModel.shared.autoStatus = st } } }
        AudioSourceMonitor.shared.setActive(on)
        if !on, autoStatus.active { autoStatus = AutoSourceStatus() }
    }

    /// Start/stop the haptic engine when mode or enabled flag changes while running.
    private func syncHapticRunState() {
        syncAutoSource()
        guard isRunning, !Self.silentLaunch else { return }
        if haptic.enabled && haptic.mode != .off { HapticEngine.shared.start() } else { HapticEngine.shared.stop() }
        hapticStatus = HapticEngine.shared.status
    }

    /// Retry audio capture when it is in a failed/needs-permission/stalled state.
    private func retryCaptureIfNeeded() {
        guard isRunning else { return }
        switch capture.state {
        case .needsPermission, .failed, .stalled:
            capture.stop(); capture.start(); audioState = capture.state
        default: break
        }
    }

    func pushSync() {
        SyncClock.shared.autoLatency = sync.auto
        SyncClock.shared.userOffset = sync.offsetMs(for: outputDeviceUID) / 1000
    }

    private func pushHaptic() {
        FeatureBus.shared.cutoffHz = haptic.cutoffHz
        HapticEngine.shared.update(haptic)
    }

    // MARK: Lifecycle

    /// Call once at launch (from the App's init / onAppear).
    func bootstrap() {
        BacklightDriver.recoverIfNeeded()
        pushSync()
        OutputLatency.shared.start()
        FeatureBus.shared.cutoffHz = haptic.cutoffHz
        FeatureBus.shared.sensitivity = onsetSensitivity

        for src in [SystemAudioTap.shared as AudioCapture, ScreenCaptureAudio.shared as AudioCapture] {
        src.sink = { ptr, n, sr in AudioAnalyzer.shared.process(ptr, count: n, sampleRate: sr) }
        src.onStateChange = { [weak self] s in
            Task { @MainActor in
                guard let self, src === self.capture else { return }
                if s != self.audioState {
                    self.audioState = s
                    if s == .needsPermission { self.showToast("System Audio Recording permission needed") }
                }
                if s != .active { FeatureBus.shared.markSilent() }
            }
        }
        }
        KeyMonitor.shared.onStatusChange = { [weak self] s in Task { @MainActor in self?.keyStatus = s } }

        GlowEngine.shared.update(glow)
        HapticEngine.shared.update(haptic)
        startMenuBarPolling()
        if !SnapshotMode.active { NowPlaying.shared.start() }
        KeySoundEngine.shared.update(sound)
        refreshPermissions()

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.shutdown() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshPermissions(); AppModel.shared.retryCaptureIfNeeded() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if AppModel.shared.isRunning { GlowEngine.shared.stop() } }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.resumeGlow(); HapticEngine.shared.reopenMotor(); AppModel.shared.retryCaptureIfNeeded() }
        }
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if AppModel.shared.isRunning { GlowEngine.shared.stop() } }
            }
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.resumeGlow() }
            }
        }
        start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        defer { syncAutoSource() }
        capture.start()
        refreshPermissions()
        if hasInputMonitoring { KeyMonitor.shared.start() }
        if glow.enabled { GlowEngine.shared.start() }
        if !Self.silentLaunch {
            if haptic.enabled && haptic.mode != .off { HapticEngine.shared.start() }
            if sound.enabled { KeySoundEngine.shared.start() }
        }
        refreshStatuses()
    }

    /// `--silent` launch flag: never start key sounds or haptics this session (UI/integration testing).
    static let silentLaunch = CommandLine.arguments.contains("--silent")

    func stop() {
        guard isRunning else { return }
        isRunning = false
        syncAutoSource()
        GlowEngine.shared.stop()
        HapticEngine.shared.stop()
        KeySoundEngine.shared.stop()
        KeyMonitor.shared.stop()
        SystemAudioTap.shared.stop()
        ScreenCaptureAudio.shared.stop()
        FeatureBus.shared.markSilent()
        refreshStatuses()
    }

    fileprivate func resumeGlow() { if isRunning && glow.enabled { GlowEngine.shared.start() } }

    func toggleRunning() { isRunning ? stop() : start() }

    /// Enable/disable individual engines while running.
    func setGlowEnabled(_ on: Bool) { glow.enabled = on; if isRunning { on ? GlowEngine.shared.start() : GlowEngine.shared.stop() }; refreshStatuses() }
    func setHapticsEnabled(_ on: Bool) { haptic.enabled = on; if isRunning && !Self.silentLaunch { on ? HapticEngine.shared.start() : HapticEngine.shared.stop() }; refreshStatuses() }
    func setSoundsEnabled(_ on: Bool) { sound.enabled = on; if isRunning && !Self.silentLaunch { on ? KeySoundEngine.shared.start() : KeySoundEngine.shared.stop() }; refreshStatuses() }

    private var didShutdown = false

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        AudioSourceMonitor.shared.setActive(false)
        GlowEngine.shared.stop(quitting: true)
        HapticEngine.shared.stop()
        KeySoundEngine.shared.shutdown()
        KeyMonitor.shared.stop()
        SystemAudioTap.shared.shutdown()
        ScreenCaptureAudio.shared.shutdown()
        QuitCoordinator.handBack()
    }

    func refreshStatuses() {
        glowStatus = GlowEngine.shared.status
        hapticStatus = HapticEngine.shared.status
        soundStatus = KeySoundEngine.shared.status
        keyStatus = KeyMonitor.shared.status
        audioState = capture.state
    }

    // MARK: Permissions

    private var loggedInputMonitoring = false

    func refreshPermissions() {
        let had = hasInputMonitoring
        hasInputMonitoring = KeyMonitor.hasPermission
        if hasInputMonitoring != had || !loggedInputMonitoring {
            loggedInputMonitoring = true
            Log.write("[perm] Input Monitoring \(hasInputMonitoring ? "granted" : "not granted")")
        }
        if hasInputMonitoring && !had && isRunning { KeyMonitor.shared.start() }
        refreshStatuses()
    }

    /// CGRequestListenEventAccess shows the system prompt only while the app has no entry in the
    /// Input Monitoring list. If an entry already exists (denied, or left by an older signature) it
    /// returns false without any UI, so open the Settings pane instead of appearing to do nothing.
    func requestInputMonitoring() {
        KeyMonitor.requestPermission()
        refreshPermissions()
        guard !hasInputMonitoring else { return }
        Log.write("[perm] Input Monitoring request returned without a grant; opening Settings")
        openPrivacySettings(.inputMonitoring)
        showToast("Turn on HapticGlow in Input Monitoring. If it is already on, remove it with − and add it again.")
    }

    func openPrivacySettings(_ pane: PrivacyPane) { NSWorkspace.shared.open(pane.url) }

    func completeOnboarding() { hasCompletedOnboarding = true; showOnboarding = false }

    // MARK: Convenience actions (bound to shortcuts / menu bar)

    func cycleGlowMode(_ delta: Int) {
        let all = GlowMode.allCases.filter { $0 != .off }
        let i = all.firstIndex(of: glow.mode) ?? 0
        glow.mode = all[(i + delta + all.count) % all.count]
        showToast(GlowModeInfo.info(glow.mode).title)
    }

    func nudgeCeiling(_ delta: Float) { glow.ceiling = max(0.05, min(1, glow.ceiling + delta)) }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self.toast = nil }
        }
    }
}

/// Display metadata for glow modes (shared by UI and toasts).
struct GlowModeInfo {
    let title: String
    let subtitle: String
    let symbol: String
    let group: String

    static func info(_ m: GlowMode) -> GlowModeInfo {
        switch m {
        case .beatPulse:  return .init(title: "Beat Pulse", subtitle: "Flares to full on every kick", symbol: "waveform.path.ecg", group: "Music")
        case .bassFollow: return .init(title: "Bass Follow", subtitle: "Rides the bass envelope", symbol: "speaker.wave.3", group: "Music")
        case .beatStrobe: return .init(title: "Beat Strobe", subtitle: "Sharp flash on each hit", symbol: "bolt", group: "Music")
        case .metronome:  return .init(title: "Metronome", subtitle: "Locks to the song's BPM", symbol: "metronome", group: "Music")
        case .spectrum:   return .init(title: "Spectrum", subtitle: "Bass body with treble sparkle", symbol: "chart.bar", group: "Music")
        case .keyPulse:   return .init(title: "Key Pulse", subtitle: "Lights up as you type", symbol: "keyboard", group: "Typing")
        case .typingHeat: return .init(title: "Typing Heat", subtitle: "Glows brighter the faster you type", symbol: "flame", group: "Typing")
        case .steady:     return .init(title: "Steady", subtitle: "Constant level", symbol: "sun.max", group: "Ambient")
        case .breathe:    return .init(title: "Breathe", subtitle: "Slow, calm breathing", symbol: "wind", group: "Ambient")
        case .heartbeat:  return .init(title: "Heartbeat", subtitle: "Lub-dub", symbol: "heart", group: "Ambient")
        case .candle:     return .init(title: "Candle", subtitle: "Warm, organic flicker", symbol: "flame.fill", group: "Ambient")
        case .aurora:     return .init(title: "Aurora", subtitle: "Layered slow waves", symbol: "sparkles", group: "Ambient")
        case .lightning:  return .init(title: "Lightning", subtitle: "Distant storm flashes", symbol: "cloud.bolt", group: "Ambient")
        case .sleep:      return .init(title: "Sleep", subtitle: "Breathing that slows and fades out", symbol: "moon.zzz", group: "Ambient")
        case .off:        return .init(title: "Off", subtitle: "Backlight untouched", symbol: "lightswitch.off", group: "Ambient")
        }
    }
}

/// Common surface of the two system-audio capture backends.
protocol AudioCapture: AnyObject {
    var sink: ((UnsafePointer<Float>, Int, Double) -> Void)? { get set }
    var onStateChange: ((AudioInputState) -> Void)? { get set }
    var state: AudioInputState { get }
    var callbackRate: Double { get }
    var sampleRate: Double { get }
    func start()
    func stop()
}
extension SystemAudioTap: AudioCapture {}
extension ScreenCaptureAudio: AudioCapture {}
