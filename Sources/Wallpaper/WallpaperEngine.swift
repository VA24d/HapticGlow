// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Desktop layer: one borderless window per screen under the desktop icons, with pause rules and playlist.
import AppKit
import ImageIO
import Observation

/// Borderless window that sits at desktop level, on every Space, and ignores the mouse.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        canHide = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    /// AppKit nudges borderless windows back inside the main screen; a desktop window must stay exactly where it is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Puts the window on `screen` in global coordinates (origin is the screen's, not the main screen's).
    /// Set again after ordering, because ordering a window in can move it to the main screen.
    func place(on screen: NSScreen) {
        let f = screen.frame
        if frame != f { setFrame(f, display: true) }
        if frame.origin != f.origin { setFrameOrigin(f.origin) }
        if let v = contentView, v.frame.size != f.size || v.frame.origin != .zero { v.frame = NSRect(origin: .zero, size: f.size) }
    }
}

@MainActor
@Observable
final class WallpaperEngine {
    static let shared = WallpaperEngine()

    // Live state for the UI.
    private(set) var isActive = false
    private(set) var pauseSummary: String?
    private(set) var lastError: String?
    private(set) var displayCount = 0

    private struct Slot {
        var window: DesktopWindow
        var surface: WallpaperSurface
        var signature: String
        var covered = false
        var frame: CGRect
    }

    private var slots: [String: Slot] = [:]
    private var gate = PauseGate()
    private var config = WallpaperConfig()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var playlistTimer: Timer?
    private var stillTasks: [String: Task<Void, Never>] = [:]
    private let library = WallpaperLibrary.shared

    private init() {}

    // MARK: Lifecycle

    /// Called by AppModel whenever the wallpaper settings change, and once at launch.
    func apply(_ new: WallpaperConfig) {
        let old = config
        config = new
        if !new.enabled {
            if isActive { tearDown(restore: true) }
            return
        }
        guard library.item(new.itemID) != nil || !new.perDisplay.isEmpty else {
            if isActive { tearDown(restore: true) }
            return
        }
        if !isActive { startObserving(); isActive = true }
        gate.set(.saver, new.pauseOnSaver && PowerState.shared.saver)
        reconcile(forceStills: old.syncLockScreen != new.syncLockScreen)
        if !new.syncLockScreen && old.syncLockScreen { DesktopPictureSync.restoreAll() }
        updatePlaylistTimer()
        refreshPlayback()
    }

    /// Quit path: stop drawing and put every screen's own desktop picture back.
    func shutdown() {
        if isActive { tearDown(restore: true) }
        else if config.syncLockScreen { DesktopPictureSync.restoreAll() }
    }

    private func tearDown(restore: Bool) {
        stopObserving()
        playlistTimer?.invalidate(); playlistTimer = nil
        stillTasks.values.forEach { $0.cancel() }; stillTasks = [:]
        for (_, s) in slots { s.surface.setPlaying(false, showStill: false); s.surface.shutdown(); s.window.orderOut(nil); s.window.close() }
        loggedState = [:]; lastSyncedFrame = [:]; lastPlaybackLog = nil
        slots = [:]
        isActive = false
        displayCount = 0
        pauseSummary = nil
        if restore { DesktopPictureSync.restoreAll() }
    }

    // MARK: Screens and surfaces

    private func itemID(for key: String) -> String? { config.perDisplay[key] ?? config.itemID }

    private var loggedState: [String: String] = [:]
    private var lastPlaybackLog: String?

    private func logDisplay(_ key: String, _ screen: NSScreen, item: WallpaperInfo, fit: WallpaperFit, px: CGSize, window: NSWindow) {
        let f = screen.frame
        let line = "\(screen.localizedName) frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) scale=\(screen.backingScaleFactor) "
            + "px=\(Int(px.width))x\(Int(px.height)) item=\(item.title) (\(item.kind.rawValue)) fit=\(fit.rawValue) "
            + "window=\(window.frame == f ? "ok" : "MISPLACED \(window.frame)")"
        if loggedState[key] != line { loggedState[key] = line; Log.write("[wallpaper] display \(key.prefix(8)) \(line)") }
    }

    private func reconcile(forceStills: Bool = false) {
        var seen = Set<String>()
        for screen in NSScreen.screens {
            guard let key = DisplayKey.of(screen) else { continue }
            seen.insert(key)
            guard let id = itemID(for: key), let item = library.item(id) else {
                if let s = slots[key] {
                    s.surface.shutdown(); s.window.orderOut(nil); s.window.close(); slots[key] = nil
                    Log.write("[wallpaper] display \(key.prefix(8)) \(screen.localizedName): no item assigned, window removed")
                }
                loggedState[key] = nil
                continue
            }
            let fit = config.fitOverrides[id] ?? item.defaultFit
            let backing = screen.backingScaleFactor
            let px = CGSize(width: (screen.frame.width * backing).rounded(), height: (screen.frame.height * backing).rounded())
            let sig = "\(id)|\(fit.rawValue)|\(config.frameRateCap)|\(Int(px.width))x\(Int(px.height))|\(backing)"
            if var slot = slots[key] {
                slot.window.place(on: screen)
                if !slot.window.isVisible { slot.window.orderBack(nil); slot.window.place(on: screen) }
                if slot.signature != sig || forceStills {
                    if slot.signature != sig {
                        slot.surface.setPlaying(false, showStill: false)
                        slot.surface.shutdown()
                        slot.surface = makeSurface(item, fit: fit, screenPixels: px, window: slot.window)
                        slot.signature = sig
                    }
                    slot.frame = screen.frame
                    slots[key] = slot
                    syncStill(screen: screen, key: key, item: item, fit: fit)
                } else {
                    slot.frame = screen.frame
                    slots[key] = slot
                    if lastSyncedFrame[key] != screen.frame { syncStill(screen: screen, key: key, item: item, fit: fit) }
                }
                logDisplay(key, screen, item: item, fit: fit, px: px, window: slot.window)
            } else {
                let w = DesktopWindow(screen: screen)
                let surface = makeSurface(item, fit: fit, screenPixels: px, window: w)
                slots[key] = Slot(window: w, surface: surface, signature: sig, frame: screen.frame)
                w.orderBack(nil)
                w.place(on: screen)
                syncStill(screen: screen, key: key, item: item, fit: fit)
                logDisplay(key, screen, item: item, fit: fit, px: px, window: w)
            }
        }
        for key in slots.keys where !seen.contains(key) {
            if let s = slots[key] { s.surface.setPlaying(false, showStill: false); s.surface.shutdown(); s.window.orderOut(nil); s.window.close() }
            slots[key] = nil
            lastSyncedFrame[key] = nil
            loggedState[key] = nil
            stillTasks[key]?.cancel(); stillTasks[key] = nil
            Log.write("[wallpaper] display \(key.prefix(8)) disconnected, window removed")
        }
        displayCount = slots.count
    }

    private func makeSurface(_ item: WallpaperInfo, fit: WallpaperFit, screenPixels: CGSize, window: DesktopWindow) -> WallpaperSurface {
        let v = WallpaperSurface(info: item, mediaURL: library.mediaURL(item), stillURL: library.stillURL(item.id),
                                 fit: fit, fpsCap: config.frameRateCap, screenPixels: screenPixels)
        window.contentView = v
        v.frame = NSRect(origin: .zero, size: window.frame.size)
        return v
    }

    // MARK: Desktop picture (lock screen, Mission Control)

    private var lastSyncedFrame: [String: CGRect] = [:]
    private var syncedStillKey: [String: String] = [:]

    /// Exports a screen-sized still and sets it as the system picture. The original is saved first.
    private func syncStill(screen: NSScreen, key: String, item: WallpaperInfo, fit: WallpaperFit) {
        guard config.syncLockScreen else { return }
        lastSyncedFrame[key] = screen.frame
        DesktopPictureSync.backUpIfNeeded(screen: screen, key: key, libraryRoot: library.root)
        let stillURL = library.stillURL(item.id)
        let dir = library.folder(item.id)
        let px = CGSize(width: (screen.frame.width * screen.backingScaleFactor).rounded(), height: (screen.frame.height * screen.backingScaleFactor).rounded())
        let backing = screen.backingScaleFactor
        stillTasks[key]?.cancel()
        stillTasks[key] = Task { [weak self] in
            let url: URL? = await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithURL(stillURL as CFURL, nil),
                      let still = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let img = StillComposer.compose(still: still, fit: fit, pixelSize: px, backing: backing, edge: EdgeColor.of(still)) else { return nil }
                // A new name each time: the system caches desktop pictures by URL.
                let prefix = "lock-\(key.prefix(8))-\(Int(px.width))x\(Int(px.height))"
                for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
                let out = dir.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970)).png")
                WallpaperLibrary.writePNG(img, to: out)
                return out
            }.value
            guard !Task.isCancelled, let url, let self else { return }
            await MainActor.run {
                guard self.isActive, self.config.syncLockScreen,
                      let scr = NSScreen.screens.first(where: { DisplayKey.of($0) == key }) else { return }
                do { try DesktopPictureSync.setPicture(url, screen: scr); self.lastError = nil }
                catch {
                    self.lastError = "Could not set the lock screen picture: \(error.localizedDescription)"
                    Log.write("[wallpaper] desktop picture set failed for \(scr.localizedName): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Replaces the exported still with the frame playing now, then refreshes the system picture.
    func useCurrentFrameAsStill() async {
        for (key, slot) in slots {
            guard let frame = await slot.surface.currentFrame() else { continue }
            library.setStill(slot.surface.info.id, frame)
            if let screen = NSScreen.screens.first(where: { DisplayKey.of($0) == key }) {
                syncStill(screen: screen, key: key, item: slot.surface.info, fit: slot.surface.fit)
            }
        }
    }

    /// For the UI: whether the current picture of the main screen can be restored by file.
    func currentPictureKind() -> DesktopPictureKind {
        if DesktopPictureSync.hasBackup() { return .restorable }
        guard let s = NSScreen.main else { return .missing }
        if let u = DesktopPictureSync.current(for: s)?.url, DesktopPictureSync.isOurs(u, libraryRoot: library.root) { return .restorable }
        return DesktopPictureSync.kind(of: s)
    }

    // MARK: Pause rules

    private func startObserving() {
        guard observers.isEmpty else { return }
        func add(_ c: NotificationCenter, _ n: Notification.Name?, _ block: @escaping @MainActor (Notification) -> Void) {
            observers.append((c, c.addObserver(forName: n, object: nil, queue: .main) { note in MainActor.assumeIsolated { block(note) } }))
        }
        let ws = NSWorkspace.shared.notificationCenter
        add(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.reconcile(); self?.refreshPlayback() }
        add(NotificationCenter.default, NSWindow.didChangeBackingPropertiesNotification) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, self.slots.values.contains(where: { $0.window === w }) else { return }
            self.reconcile(); self.refreshPlayback()
        }
        add(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { [weak self] n in self?.occlusionChanged(n.object as? NSWindow) }
        add(ws, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.set(.displaySleep, true) }
        add(ws, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.set(.displaySleep, false) }
        add(ws, NSWorkspace.willSleepNotification) { [weak self] _ in self?.set(.displaySleep, true) }
        add(ws, NSWorkspace.didWakeNotification) { [weak self] _ in self?.set(.displaySleep, false) }
        add(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.set(.sessionInactive, true) }
        add(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.set(.sessionInactive, false) }
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.set(.locked, true) }
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.set(.locked, false) }
        add(NotificationCenter.default, PowerState.didChange) { [weak self] _ in
            guard let self else { return }
            self.set(.saver, self.config.pauseOnSaver && PowerState.shared.saver)
        }
    }

    private func stopObserving() {
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        gate = PauseGate()
    }

    private func set(_ r: PauseReason, _ on: Bool) {
        gate.set(r, on)
        refreshPlayback()
    }

    private func occlusionChanged(_ w: NSWindow?) {
        guard let w, let key = slots.first(where: { $0.value.window === w })?.key else { return }
        slots[key]?.covered = config.pauseWhenCovered && !w.occlusionState.contains(.visible)
        refreshPlayback()
    }

    /// Plays or holds every surface. Holding cancels the frame timer / pauses the player, it does not just hide.
    private func refreshPlayback() {
        var covered = 0
        for (key, s) in slots {
            let isCovered = config.pauseWhenCovered && s.covered
            if isCovered { covered += 1 }
            let hold = gate.isPaused || isCovered
            s.surface.setPlaying(!hold, showStill: gate.showsStill)
            _ = key
        }
        let state = slots.keys.sorted().map { k in
            "\(k.prefix(8))=" + ((gate.isPaused || (config.pauseWhenCovered && slots[k]?.covered == true)) ? "held" : "playing")
        }.joined(separator: " ") + (gate.summary.map { " (\($0))" } ?? "")
        if state != lastPlaybackLog { lastPlaybackLog = state; Log.write("[wallpaper] playback \(state)") }
        if let g = gate.summary { pauseSummary = "Paused: \(g)" }
        else if !slots.isEmpty, covered == slots.count { pauseSummary = "Paused: \(PauseReason.covered.text)" }
        else if covered > 0 { pauseSummary = "Paused on \(covered) of \(slots.count) displays: covered" }
        else { pauseSummary = nil }
    }

    // MARK: Playlist

    private func updatePlaylistTimer() {
        playlistTimer?.invalidate(); playlistTimer = nil
        guard isActive, config.playlistEnabled, config.playlistIDs.count > 1 else { return }
        let t = Timer.scheduledTimer(withTimeInterval: Double(max(1, config.playlistMinutes)) * 60, repeats: true) { _ in
            MainActor.assumeIsolated { WallpaperEngine.shared.advancePlaylist() }
        }
        t.tolerance = min(60, Double(config.playlistMinutes) * 6)
        playlistTimer = t
    }

    func advancePlaylist() {
        let ids = config.playlistIDs.filter { library.item($0) != nil }
        guard ids.count > 1 else { return }
        let next = WallpaperPlaylist.next(after: config.itemID, in: ids)
        AppModel.shared.wallpaper.itemID = next
    }
}
