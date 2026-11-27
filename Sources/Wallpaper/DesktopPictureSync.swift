// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Keeps the system desktop picture (lock screen, Mission Control, Spaces) in step with the live wallpaper,
// and puts each screen's original picture back when the engine stops.
import AppKit
import ImageIO

/// A display's identity that survives reboots and re-plugging.
enum DisplayKey {
    static func of(_ screen: NSScreen) -> String? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, u) as String? else { return nil }
        return s
    }
}

/// What one screen's desktop picture looked like before the engine changed it.
struct DesktopPictureEntry: Codable, Equatable, Sendable {
    var path: String
    var scaling: UInt?
    var allowClipping: Bool?
    var fill: [Double]?   // r, g, b, a in sRGB
}

enum DesktopPictureSync {
    static var backupFile: URL {
        WallpaperLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("desktop-backup.json")
    }

    // MARK: Pure helpers (also used by the test harness)

    static func encode(url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any]) -> DesktopPictureEntry {
        var e = DesktopPictureEntry(path: url.path)
        if let s = options[.imageScaling] as? NSNumber { e.scaling = s.uintValue }
        if let c = options[.allowClipping] as? NSNumber { e.allowClipping = c.boolValue }
        if let col = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            e.fill = [Double(col.redComponent), Double(col.greenComponent), Double(col.blueComponent), Double(col.alphaComponent)]
        }
        return e
    }

    static func options(from e: DesktopPictureEntry) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var o: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let s = e.scaling { o[.imageScaling] = NSNumber(value: s) }
        if let c = e.allowClipping { o[.allowClipping] = NSNumber(value: c) }
        if let f = e.fill, f.count == 4 { o[.fillColor] = NSColor(srgbRed: f[0], green: f[1], blue: f[2], alpha: f[3]) }
        return o
    }

    /// Whether a picture's URL points inside the library (our own exported still, not the user's wallpaper).
    static func isOurs(_ url: URL, libraryRoot: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(libraryRoot.standardizedFileURL.path + "/")
    }

    // MARK: Backup store

    static func loadBackup() -> [String: DesktopPictureEntry] {
        guard let d = try? Data(contentsOf: backupFile) else { return [:] }
        return (try? JSONDecoder().decode([String: DesktopPictureEntry].self, from: d)) ?? [:]
    }

    static func saveBackup(_ b: [String: DesktopPictureEntry]) {
        if b.isEmpty { try? FileManager.default.removeItem(at: backupFile); return }
        try? FileManager.default.createDirectory(at: backupFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: backupFile, options: .atomic) }
    }

    /// Reads (never writes) a screen's current desktop picture.
    static func current(for screen: NSScreen) -> (url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any])? {
        guard let u = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return (u, NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
    }

    static func kind(of screen: NSScreen) -> DesktopPictureKind {
        let url = current(for: screen)?.url
        return DesktopPictureClassifier.classify(path: url?.path, fileExists: url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    /// True when a backup is already held (the original is safe) or every screen has restorable pictures.
    static func hasBackup() -> Bool { !loadBackup().isEmpty }

    /// Saves the screen's original picture the first time the engine is about to change it.
    static func backUpIfNeeded(screen: NSScreen, key: String, libraryRoot: URL) {
        var b = loadBackup()
        guard b[key] == nil, let cur = current(for: screen), !isOurs(cur.url, libraryRoot: libraryRoot) else { return }
        b[key] = encode(url: cur.url, options: cur.options)
        saveBackup(b)
    }

    static func setPicture(_ url: URL, screen: NSScreen) throws {
        let o: [NSWorkspace.DesktopImageOptionKey: Any] = [.imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                                                           .allowClipping: NSNumber(value: true)]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: o)
        Log.write("[wallpaper] desktop picture set: \(screen.localizedName) <- \(url.lastPathComponent)")
    }

    /// Puts every backed-up screen's original picture back, then forgets the backup. Screens that are not
    /// connected keep their entry for next time. Entries whose file is gone are dropped.
    @discardableResult
    static func restoreAll() -> Int {
        var b = loadBackup()
        var restored = 0
        for screen in NSScreen.screens {
            guard let key = DisplayKey.of(screen), let e = b[key] else { continue }
            let url = URL(fileURLWithPath: e.path)
            if FileManager.default.fileExists(atPath: e.path) {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options(from: e)); restored += 1
                    Log.write("[wallpaper] desktop picture restored: \(screen.localizedName) <- \(url.lastPathComponent)")
                } catch { Log.write("[wallpaper] restore failed for \(screen.localizedName): \(error.localizedDescription)"); continue }
            } else {
                Log.write("[wallpaper] original picture of \(screen.localizedName) is gone, dropping its backup")
            }
            b[key] = nil
        }
        saveBackup(b)
        return restored
    }
}

/// Renders a still the size of one screen, so the lock screen picture matches the live wallpaper's fit exactly.
enum StillComposer {
    static func compose(still: CGImage, fit: WallpaperFit, pixelSize: CGSize, backing: CGFloat, edge: CGColor) -> CGImage? {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard w > 0, h > 0, w * h <= 16384 * 16384 / 4 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(still, into: ctx, fit: fit, pixelSize: pixelSize, backing: backing, edge: edge)
        return ctx.makeImage()
    }

    /// Fills `ctx` (w x h device pixels) with the edge colour and draws the image with the live wallpaper's fit.
    static func draw(_ still: CGImage, into ctx: CGContext, fit: WallpaperFit, pixelSize: CGSize, backing: CGFloat, edge: CGColor) {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        ctx.setFillColor(edge)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let pts = CGSize(width: pixelSize.width / backing, height: pixelSize.height / backing)
        let r = WallpaperLayout.rect(fit: fit, content: CGSize(width: still.width, height: still.height), bounds: pts, backing: backing)
        // Whole device pixels, and no interpolation at all for pixel art: a 960x540 frame on a 3840x2160 still is exactly 4x.
        let dst = CGRect(x: (r.minX * backing).rounded(), y: (r.minY * backing).rounded(),
                         width: (r.width * backing).rounded(), height: (r.height * backing).rounded())
        ctx.interpolationQuality = fit == .pixelArt ? .none : .high
        ctx.draw(still, in: dst)
    }
}
