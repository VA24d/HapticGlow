// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Opt-in "Use on lock screen": exports an item, then installs it as a custom Aerial entry in one admin-authorised step.
import AppKit
import Foundation

enum LockScreenError: Error, LocalizedError {
    case layoutMissing, noScript, cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .layoutMissing:
            return "No Aerial catalog was found on this Mac (neither ~/Library/Application Support/com.apple.wallpaper/aerials nor \(LockScreenCatalog.customerPath)), so nothing was changed."
        case .noScript: return "The install script is missing from the app, so nothing was changed."
        case .cancelled: return "Cancelled. Nothing was changed."
        case .failed(let m): return m
        }
    }
}
@MainActor
enum LockScreenInstaller {
    // MARK: Where the catalog lives

    /// Test hook: a copy of the user-level `aerials` folder. Never set in the app.
    static var userBaseOverride: URL?

    /// The user-level Aerial store macOS 26 reads (no administrator rights needed).
    static var userBase: URL {
        userBaseOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }
    static var userManifest: URL { userBase.appendingPathComponent("manifest/entries.json") }
    static var userVideos: URL { userBase.appendingPathComponent("videos", isDirectory: true) }
    static var userThumbs: URL { userBase.appendingPathComponent("thumbnails", isDirectory: true) }
    /// HEIF previews (the entry's previewImage), one per entry.
    static var userSnapshots: URL { userBase.appendingPathComponent(LockScreenCatalog.previewFolder, isDirectory: true) }
    static var userCatalogPresent: Bool { FileManager.default.fileExists(atPath: userManifest.path) }

    static var customerURL: URL { URL(fileURLWithPath: LockScreenCatalog.customerPath, isDirectory: true) }
    static var entriesURL: URL { customerURL.appendingPathComponent("entries.json") }
    /// The app's own data folder (`HapticGlow` in Application Support); a sibling of the test base when one is set.
    static var workRoot: URL {
        userBaseOverride.map { $0.deletingLastPathComponent().appendingPathComponent("HapticGlowData", isDirectory: true) }
            ?? WallpaperLibrary.defaultRoot.deletingLastPathComponent()
    }
    static var backupsFolder: URL { workRoot.appendingPathComponent("lockscreen-backups", isDirectory: true) }
    static var stillsFolder: URL { workRoot.appendingPathComponent(LockScreenIndex.stillsFolderName, isDirectory: true) }
    /// The wallpaper store macOS reads the Desktop and Idle (screen saver / lock screen) choices from.
    static var indexURL: URL { userBase.deletingLastPathComponent().appendingPathComponent("Store/Index.plist") }
    private static var stateURL: URL { workRoot.appendingPathComponent("lockscreen-state.json") }

    /// The system folder has to exist (it is created by macOS); the entries.json inside it may not exist yet.
    static func systemLayoutPresent() -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: LockScreenCatalog.customerPath, isDirectory: &dir) && dir.boolValue
    }

    /// The catalog file in use: the user-level one when it exists, else the system one.
    private static var activeEntries: URL { userCatalogPresent ? userManifest : entriesURL }

    static func isInstalled(itemID: String) -> Bool {
        LockScreenCatalog.installedIDs(in: try? Data(contentsOf: activeEntries)).contains(LockScreenCatalog.assetID(for: itemID))
    }

    static func hasAnyInstalled() -> Bool {
        if !LockScreenCatalog.installedIDs(in: try? Data(contentsOf: activeEntries)).isEmpty { return true }
        return (try? Data(contentsOf: indexURL)).flatMap { try? LockScreenIndex.decode($0).root }.map { LockScreenIndex.ourIdleCount($0) > 0 } ?? false
    }

    private static let afterInstall = "Added \"%@\" to the Aerial list (4K, 60 fps). It is not selected for you: open System Settings, Wallpaper, scroll to the HapticGlow category under Aerials and pick it as the screen saver, which is what plays on the lock screen. If it does not appear yet, sign out and back in."

    // MARK: Install

    /// Exports `item`, then installs the entry. Returns the message to show the user.
    static func install(item: WallpaperInfo, mediaURL: URL, fit: WallpaperFit, screen: NSScreen?) async throws -> String {
        let user = userCatalogPresent
        guard user || systemLayoutPresent() else { Log.write("[wallpaper] lock screen: no catalog found, nothing done"); throw LockScreenError.layoutMissing }
        // Refuse before exporting anything when the user-level catalog is not the layout we know.
        let userData = user ? try? Data(contentsOf: userManifest) : nil
        if user {
            guard let userData else { throw LockScreenError.failed("The Aerial catalog could not be read, so nothing was changed.") }
            do { try LockScreenCatalog.checkUserSchema(userData) } catch { Log.write("[wallpaper] lock screen: schema refused: \(error.localizedDescription)"); throw LockScreenError.failed(error.localizedDescription) }
        }
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let id = LockScreenCatalog.assetID(for: item.id)
        let size = LockScreenExporter.targetSize(screen: screen)
        Log.write("[wallpaper] lock screen: exporting \(item.title) as \(id.prefix(8)) at \(Int(LockScreenExporter.canvas.width))x\(Int(LockScreenExporter.canvas.height)) HEVC Main10, \(LockScreenExporter.fps) fps, fit \(fit.rawValue), \(user ? "user catalog" : "system catalog")")
        let files: (mov: URL, preview: URL)
        do { files = try await LockScreenExporter.export(item: item, mediaURL: mediaURL, fit: fit, size: size, id: id, into: stage) }
        catch { throw LockScreenError.failed(error.localizedDescription) }
        let asset = LockScreenCatalog.Asset(id: id, title: item.title)

        if user, let userData {
            let fm = FileManager.default
            let video = userVideos.appendingPathComponent("\(id).mov")
            let preview = userSnapshots.appendingPathComponent("\(id).heic"), thumb = userThumbs.appendingPathComponent("\(id).png")
            let links = LockScreenCatalog.Links(video: video.absoluteURL.absoluteString, preview: preview.absoluteURL.absoluteString)
            let newManifest: Data
            do { newManifest = try LockScreenCatalog.adding(asset, to: userData, links: links) } catch { throw LockScreenError.failed(error.localizedDescription) }
            try backUpOriginal(userData, next: userManifest)
            do {
                try fm.createDirectory(at: userVideos, withIntermediateDirectories: true)
                try fm.createDirectory(at: userSnapshots, withIntermediateDirectories: true)
                try fm.createDirectory(at: userThumbs, withIntermediateDirectories: true)
                try replace(video, with: files.mov)
                try replace(preview, with: files.preview)
                if let src = CGImageSourceCreateWithURL(files.preview as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                   let small = WallpaperLibrary.downsample(img, maxPixel: 480) {
                    WallpaperLibrary.writePNG(small, to: thumb)
                }
                try newManifest.write(to: userManifest, options: .atomic)
            } catch {
                for f in [video, preview, thumb] { try? fm.removeItem(at: f) }
                Log.write("[wallpaper] lock screen: install failed, files removed: \(error.localizedDescription)")
                throw LockScreenError.failed("Could not write the Aerial catalog: \(error.localizedDescription)")
            }
            remember(asset)
            Log.write("[wallpaper] lock screen: wrote \(video.lastPathComponent), \(preview.lastPathComponent), \(thumb.lastPathComponent) and the catalog entry for \(id.prefix(8))")
            restartAgents()
            Log.write("[wallpaper] lock screen: installed \(id.prefix(8)) in the user catalog")
            return String(format: afterInstall, item.title)
        }

        let script = try scriptURL()
        let existing = try? Data(contentsOf: entriesURL)
        try backUpOriginal(existing, next: nil)
        do { try LockScreenCatalog.adding(asset, to: existing, links: LockScreenCatalog.systemLinks(id)).write(to: stage.appendingPathComponent("entries.json")) }
        catch { throw LockScreenError.failed(error.localizedDescription) }
        try runPrivileged(script: script, mode: "install", stage: stage)
        Log.write("[wallpaper] lock screen: installed \(id.prefix(8)) in the system catalog")
        return String(format: afterInstall, item.title)
    }

    /// Removes only HapticGlow entries (and their files) and leaves every other entry as it was.
    static func removeAll() async throws -> String {
        let user = userCatalogPresent
        let hadStill = (try? Data(contentsOf: indexURL)).flatMap { try? LockScreenIndex.decode($0).root }.map { LockScreenIndex.ourIdleCount($0) > 0 } ?? false
        if hadStill { restoreIndex() }
        guard user || systemLayoutPresent() else {
            if hadStill { restartAgents(); return "The lock screen picture was put back as it was before." }
            throw LockScreenError.layoutMissing
        }
        guard let existing = try? Data(contentsOf: activeEntries) else {
            if hadStill { restartAgents(); return "The lock screen picture was put back as it was before." }
            return "Nothing to remove."
        }
        let data: Data, ids: [String]
        do { (data, ids) = try LockScreenCatalog.removingOurs(from: existing) } catch { throw LockScreenError.failed(error.localizedDescription) }
        if ids.isEmpty {
            if hadStill { restartAgents(); return "The lock screen picture was put back as it was before." }
            return "Nothing to remove."
        }
        saveState(State())
        if user {
            try backUpOriginal(existing, next: userManifest)
            do { try data.write(to: userManifest, options: .atomic) }
            catch { throw LockScreenError.failed("Could not write the Aerial catalog: \(error.localizedDescription)") }
            for id in ids where UUID(uuidString: id) != nil {
                try? FileManager.default.removeItem(at: userVideos.appendingPathComponent("\(id).mov"))
                try? FileManager.default.removeItem(at: userSnapshots.appendingPathComponent("\(id).heic"))
                try? FileManager.default.removeItem(at: userThumbs.appendingPathComponent("\(id).png"))
            }
            restartAgents()
        } else {
            let script = try scriptURL()
            let stage = try makeStage()
            defer { try? FileManager.default.removeItem(at: stage) }
            try backUpOriginal(existing, next: nil)
            try data.write(to: stage.appendingPathComponent("entries.json"))
            try ids.joined(separator: "\n").write(to: stage.appendingPathComponent("remove.txt"), atomically: true, encoding: .utf8)
            try runPrivileged(script: script, mode: "remove", stage: stage)
        }
        Log.write("[wallpaper] lock screen: removed \(ids.count) entr\(ids.count == 1 ? "y" : "ies")")
        return "Removed from the lock screen catalog. If you picked one of these in System Settings, choose another wallpaper there."
    }

    /// Restarts the signed-in user's wallpaper agent and Aerials extension (launchd starts them again). No sudo.
    private static func restartAgents() {
        guard userBaseOverride == nil else { Log.write("[wallpaper] lock screen: test base, wallpaper processes not restarted"); return }
        for name in ["WallpaperAgent", "WallpaperAerialsExtension"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [name]
            p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); Log.write("[wallpaper] lock screen: restarted \(name) (exit \(p.terminationStatus))") }
            catch { Log.write("[wallpaper] lock screen: could not restart \(name): \(error.localizedDescription)") }
        }
    }

    // MARK: Entries macOS drops, and the still option

    private struct State: Codable { var items: [Item] = []; struct Item: Codable { var id: String; var title: String } }
    private static func loadState() -> State { (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State() }
    private static func saveState(_ s: State) {
        try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: stateURL, options: .atomic) }
    }
    private static func remember(_ a: LockScreenCatalog.Asset) {
        var s = loadState()
        s.items.removeAll { $0.id == a.id }
        s.items.append(.init(id: a.id, title: a.title))
        saveState(s)
    }

    /// At launch: when macOS replaced entries.json with a new Aerial list (our entries are gone but our files remain),
    /// adds the entries back and restarts the two wallpaper processes. Returns how many entries were re-added.
    @discardableResult
    static func reapplyIfNeeded() -> Int {
        guard userCatalogPresent, let data = try? Data(contentsOf: userManifest) else { return 0 }
        let have = Set(LockScreenCatalog.installedIDs(in: data))
        let missing = loadState().items.filter {
            !have.contains($0.id) && FileManager.default.fileExists(atPath: userVideos.appendingPathComponent("\($0.id).mov").path)
        }
        guard !missing.isEmpty else { return 0 }
        guard (try? LockScreenCatalog.checkUserSchema(data)) != nil else {
            Log.write("[wallpaper] lock screen: catalog was replaced but its layout is unknown, entries not re-added"); return 0
        }
        Log.write("[wallpaper] lock screen: macOS replaced the Aerial catalog, \(missing.count) HapticGlow entr\(missing.count == 1 ? "y" : "ies") missing")
        var next = data
        do {
            for m in missing {
                let links = LockScreenCatalog.Links(video: userVideos.appendingPathComponent("\(m.id).mov").absoluteURL.absoluteString,
                                                    preview: userSnapshots.appendingPathComponent("\(m.id).heic").absoluteURL.absoluteString)
                next = try LockScreenCatalog.adding(.init(id: m.id, title: m.title), to: next, links: links)
            }
            try backUpOriginal(data, next: userManifest)
            try next.write(to: userManifest, options: .atomic)
        } catch { Log.write("[wallpaper] lock screen: could not re-add entries: \(error.localizedDescription)"); return 0 }
        Log.write("[wallpaper] lock screen: re-added \(missing.count) entr\(missing.count == 1 ? "y" : "ies")")
        restartAgents()
        return missing.count
    }

    /// Sets a still of the item as the Idle (screen saver / lock screen) picture in Store/Index.plist, after a backup.
    /// When that file cannot be edited, sets the desktop picture instead, which the lock screen also shows.
    static func useStill(item: WallpaperInfo, stillURL: URL, fit: WallpaperFit, screen: NSScreen?) async throws -> String {
        let size = LockScreenExporter.targetSize(screen: screen)
        let backing = screen?.backingScaleFactor ?? 1
        let prefix = LockScreenCatalog.assetID(for: item.id).prefix(8)
        let dir = stillsFolder
        let out = dir.appendingPathComponent("\(prefix)-\(Int(Date().timeIntervalSince1970)).png")
        let ok: Bool = await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(stillURL as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let composed = StillComposer.compose(still: img, fit: fit, pixelSize: size, backing: backing, edge: EdgeColor.of(img)) else { return false }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            WallpaperLibrary.writePNG(composed, to: out)
            return FileManager.default.fileExists(atPath: out.path)
        }.value
        guard ok else { throw LockScreenError.failed("The still picture could not be created, so nothing was changed.") }
        Log.write("[wallpaper] lock screen: still \(out.lastPathComponent) written at \(Int(size.width))x\(Int(size.height))")

        if let data = try? Data(contentsOf: indexURL), let (root, fmt) = try? LockScreenIndex.decode(data), LockScreenIndex.hasTemplate(root) {
            do {
                let (next, n) = try LockScreenIndex.settingStill(out, in: root)
                if LockScreenIndex.ourIdleCount(root) == 0 {
                    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
                    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                    try data.write(to: backupsFolder.appendingPathComponent("Index-\(stamp).plist"))
                    Log.write("[wallpaper] lock screen: backed up Index.plist")
                }
                try LockScreenIndex.encode(next, format: fmt).write(to: indexURL, options: .atomic)
                Log.write("[wallpaper] lock screen: Idle choice set to the still in \(n) place\(n == 1 ? "" : "s")")
                restartAgents()
                pruneStills(keeping: out)
                return "\"\(item.title)\" is now the lock screen picture (and the screen saver picture). Remove from Lock Screen puts the old choice back."
            } catch { Log.write("[wallpaper] lock screen: Index.plist edit failed: \(error.localizedDescription)") }
        }
        guard let screen, userBaseOverride == nil else { throw LockScreenError.failed("The wallpaper settings could not be edited and no screen was found, so nothing was changed.") }
        let key = DisplayKey.of(screen) ?? "main"
        DesktopPictureSync.backUpIfNeeded(screen: screen, key: key, libraryRoot: WallpaperLibrary.defaultRoot)
        do { try DesktopPictureSync.setPicture(out, screen: screen) } catch { throw LockScreenError.failed("Could not set the picture: \(error.localizedDescription)") }
        Log.write("[wallpaper] lock screen: Index.plist not editable, set the desktop picture instead")
        return "The lock screen settings could not be edited, so the still was set as the desktop picture instead. The lock screen shows it when it uses the desktop picture."
    }

    /// Deletes older stills of ours once a new one is in place.
    private static func pruneStills(keeping: URL) {
        for f in (try? FileManager.default.contentsOfDirectory(at: stillsFolder, includingPropertiesForKeys: nil)) ?? [] where f != keeping {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Puts the Idle choice back from the newest Index.plist backup (only the nodes that show our still).
    private static func restoreIndex() {
        guard let data = try? Data(contentsOf: indexURL), let (root, fmt) = try? LockScreenIndex.decode(data), LockScreenIndex.ourIdleCount(root) > 0 else { return }
        let newest = ((try? FileManager.default.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Index-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
        let backup = newest.flatMap { try? Data(contentsOf: $0) }.flatMap { try? LockScreenIndex.decode($0).root }
        let (next, n) = LockScreenIndex.restoring(root, from: backup)
        do {
            try LockScreenIndex.encode(next, format: fmt).write(to: indexURL, options: .atomic)
            Log.write("[wallpaper] lock screen: restored \(n) Idle choice\(n == 1 ? "" : "s") from \(backup == nil ? "defaults (no backup found)" : "the Index.plist backup")")
        } catch { Log.write("[wallpaper] lock screen: could not restore Index.plist: \(error.localizedDescription)") }
        try? FileManager.default.removeItem(at: stillsFolder)
    }

    private static func replace(_ dest: URL, with src: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: src, to: dest)
    }

    // MARK: Helpers

    private static func scriptURL() throws -> URL {
        guard let u = Bundle.main.url(forResource: "lockscreen-install", withExtension: "sh") else { throw LockScreenError.noScript }
        return u
    }

    /// A private (0700) folder inside the user's temp folder, named by the app. The script refuses anything else.
    private static func makeStage() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("HapticGlowLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return u
    }

    /// Timestamped copy of the catalog as macOS wrote it: in the app's folder, and next to the file when `next` is given
    /// (the admin script keeps its own copy for the system catalog). Only taken while the catalog holds no HapticGlow
    /// entry, so every backup is a pre-HapticGlow original, including after macOS refreshes the catalog.
    private static func backUpOriginal(_ existing: Data?, next: URL?) throws {
        guard let existing, !existing.isEmpty, LockScreenCatalog.installedIDs(in: existing).isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try existing.write(to: backupsFolder.appendingPathComponent("entries-\(stamp).json"))
        if let next { try existing.write(to: next.deletingLastPathComponent().appendingPathComponent("entries.json.hapticglow-backup-\(stamp)")) }
    }

    /// Single-quotes a string for /bin/sh. The values passed here are paths the app created itself.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Escapes a string for use inside an AppleScript string literal.
    static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The one authorised step: `do shell script ... with administrator privileges` running the fixed script.
    private static func runPrivileged(script: URL, mode: String, stage: URL) throws {
        let prefix = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        let cmd = ["/bin/bash", script.path, mode, stage.path, prefix].map(shellQuote).joined(separator: " ")
        let src = "do shell script \(appleScriptLiteral(cmd)) with administrator privileges"
        var err: NSDictionary?
        guard let as_ = NSAppleScript(source: src) else { throw LockScreenError.failed("Could not prepare the administrator request.") }
        _ = as_.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { throw LockScreenError.cancelled }
            let m = (err[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            Log.write("[wallpaper] lock screen: install step failed: \(m)")
            throw LockScreenError.failed("The install step failed: \(m)")
        }
    }
}
