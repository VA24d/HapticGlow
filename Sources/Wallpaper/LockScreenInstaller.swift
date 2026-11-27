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
    static var userCatalogPresent: Bool { FileManager.default.fileExists(atPath: userManifest.path) }

    static var customerURL: URL { URL(fileURLWithPath: LockScreenCatalog.customerPath, isDirectory: true) }
    static var entriesURL: URL { customerURL.appendingPathComponent("entries.json") }
    static var backupsFolder: URL { WallpaperLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("lockscreen-backups", isDirectory: true) }

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

    static func hasAnyInstalled() -> Bool { !LockScreenCatalog.installedIDs(in: try? Data(contentsOf: activeEntries)).isEmpty }

    private static let afterInstall = "Open System Settings, Wallpaper, then pick \"%@\" in the HapticGlow category (and as the screen saver if you want it there). macOS plays it animated on the lock screen. If it does not appear yet, sign out and back in."

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
        Log.write("[wallpaper] lock screen: exporting \(item.title) as \(id.prefix(8)) at \(Int(size.width))x\(Int(size.height)), fit \(fit.rawValue), \(user ? "user catalog" : "system catalog")")
        let files: (mov: URL, jpg: URL)
        do { files = try await LockScreenExporter.export(item: item, mediaURL: mediaURL, fit: fit, size: size, id: id, into: stage) }
        catch { throw LockScreenError.failed(error.localizedDescription) }
        let asset = LockScreenCatalog.Asset(id: id, title: item.title)

        if user, let userData {
            let fm = FileManager.default
            let video = userVideos.appendingPathComponent("\(id).mov"), thumb = userThumbs.appendingPathComponent("\(id).png")
            let links = LockScreenCatalog.Links(video: video.absoluteURL.absoluteString, preview: thumb.absoluteURL.absoluteString)
            let newManifest: Data
            do { newManifest = try LockScreenCatalog.adding(asset, to: userData, links: links) } catch { throw LockScreenError.failed(error.localizedDescription) }
            try backUpOriginal(userData, next: userManifest)
            do {
                try fm.createDirectory(at: userVideos, withIntermediateDirectories: true)
                try fm.createDirectory(at: userThumbs, withIntermediateDirectories: true)
                try replace(video, with: files.mov)
                if let src = CGImageSourceCreateWithURL(files.jpg as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    WallpaperLibrary.writePNG(img, to: thumb)
                }
                try newManifest.write(to: userManifest, options: .atomic)
            } catch {
                try? fm.removeItem(at: video); try? fm.removeItem(at: thumb)
                throw LockScreenError.failed("Could not write the Aerial catalog: \(error.localizedDescription)")
            }
            restartWallpaperAgent()
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
        guard user || systemLayoutPresent() else { throw LockScreenError.layoutMissing }
        guard let existing = try? Data(contentsOf: activeEntries) else { return "Nothing to remove." }
        let data: Data, ids: [String]
        do { (data, ids) = try LockScreenCatalog.removingOurs(from: existing) } catch { throw LockScreenError.failed(error.localizedDescription) }
        guard !ids.isEmpty else { return "Nothing to remove." }
        if user {
            try backUpOriginal(existing, next: userManifest)
            do { try data.write(to: userManifest, options: .atomic) }
            catch { throw LockScreenError.failed("Could not write the Aerial catalog: \(error.localizedDescription)") }
            for id in ids where UUID(uuidString: id) != nil {
                try? FileManager.default.removeItem(at: userVideos.appendingPathComponent("\(id).mov"))
                try? FileManager.default.removeItem(at: userThumbs.appendingPathComponent("\(id).png"))
            }
            restartWallpaperAgent()
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

    /// Restarts the signed-in user's wallpaper agent (launchd starts it again). No sudo.
    private static func restartWallpaperAgent() {
        guard userBaseOverride == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        try? p.run()
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
