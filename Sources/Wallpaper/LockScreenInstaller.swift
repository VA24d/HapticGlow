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
            return "This Mac does not have the Aerial custom folder (\(LockScreenCatalog.customerPath)), so nothing was changed. The lock screen cannot be set up here."
        case .noScript: return "The install script is missing from the app, so nothing was changed."
        case .cancelled: return "Cancelled. Nothing was changed."
        case .failed(let m): return m
        }
    }
}

@MainActor
enum LockScreenInstaller {
    static var customerURL: URL { URL(fileURLWithPath: LockScreenCatalog.customerPath, isDirectory: true) }
    static var entriesURL: URL { customerURL.appendingPathComponent("entries.json") }
    static var backupsFolder: URL { WallpaperLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("lockscreen-backups", isDirectory: true) }

    /// The system folder has to exist (it is created by macOS); the entries.json inside it may not exist yet.
    static func layoutPresent() -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: LockScreenCatalog.customerPath, isDirectory: &dir) && dir.boolValue
    }

    static func isInstalled(itemID: String) -> Bool {
        LockScreenCatalog.installedIDs(in: try? Data(contentsOf: entriesURL)).contains(LockScreenCatalog.assetID(for: itemID))
    }

    static func hasAnyInstalled() -> Bool { !LockScreenCatalog.installedIDs(in: try? Data(contentsOf: entriesURL)).isEmpty }

    // MARK: Install

    /// Exports `item`, asks for administrator rights once, installs the entry. Returns the message to show the user.
    static func install(item: WallpaperInfo, mediaURL: URL, fit: WallpaperFit, screen: NSScreen?) async throws -> String {
        guard layoutPresent() else { Log.write("[wallpaper] lock screen: catalog folder missing, nothing done"); throw LockScreenError.layoutMissing }
        let script = try scriptURL()
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        let id = LockScreenCatalog.assetID(for: item.id)
        let size = LockScreenExporter.targetSize(screen: screen)
        Log.write("[wallpaper] lock screen: exporting \(item.title) as \(id.prefix(8)) at \(Int(size.width))x\(Int(size.height)), fit \(fit.rawValue)")
        do { _ = try await LockScreenExporter.export(item: item, mediaURL: mediaURL, fit: fit, size: size, id: id, into: stage) }
        catch { throw LockScreenError.failed(error.localizedDescription) }

        let existing = try? Data(contentsOf: entriesURL)
        try backUpOriginal(existing)
        do { try LockScreenCatalog.adding(.init(id: id, title: item.title), to: existing).write(to: stage.appendingPathComponent("entries.json")) }
        catch { throw LockScreenError.failed(error.localizedDescription) }
        try runPrivileged(script: script, mode: "install", stage: stage)
        Log.write("[wallpaper] lock screen: installed \(id.prefix(8))")
        return "Added to the lock screen catalog. Open System Settings, Wallpaper, then pick \"\(item.title)\" in the HapticGlow category (and as the screen saver if you want it there). macOS plays it animated on the lock screen. If it does not appear yet, sign out and back in."
    }

    /// Removes only HapticGlow entries (and their files) and leaves every other entry as it was.
    static func removeAll() async throws -> String {
        guard layoutPresent() else { throw LockScreenError.layoutMissing }
        guard let existing = try? Data(contentsOf: entriesURL) else { return "Nothing to remove." }
        let data: Data, ids: [String]
        do { (data, ids) = try LockScreenCatalog.removingOurs(from: existing) } catch { throw LockScreenError.failed(error.localizedDescription) }
        guard !ids.isEmpty else { return "Nothing to remove." }
        let script = try scriptURL()
        let stage = try makeStage()
        defer { try? FileManager.default.removeItem(at: stage) }
        try backUpOriginal(existing)
        try data.write(to: stage.appendingPathComponent("entries.json"))
        try ids.joined(separator: "\n").write(to: stage.appendingPathComponent("remove.txt"), atomically: true, encoding: .utf8)
        try runPrivileged(script: script, mode: "remove", stage: stage)
        Log.write("[wallpaper] lock screen: removed \(ids.count) entr\(ids.count == 1 ? "y" : "ies")")
        return "Removed from the lock screen catalog. If you picked one of these in System Settings, choose another wallpaper there."
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

    /// Timestamped copy of the original entries.json in the app's own folder (the script also keeps one next to the original).
    private static func backUpOriginal(_ existing: Data?) throws {
        guard let existing, !existing.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        let hasOriginal = ((try? fm.contentsOfDirectory(atPath: backupsFolder.path)) ?? []).contains { $0.hasPrefix("entries-") }
        guard !hasOriginal else { return }   // keep the first (pre-HapticGlow) copy; later ones would already contain our entries
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try existing.write(to: backupsFolder.appendingPathComponent("entries-\(stamp).json"))
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
