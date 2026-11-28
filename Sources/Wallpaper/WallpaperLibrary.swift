// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Wallpaper library: one folder per item with the media, a thumbnail, a still and info.json.
import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Observation

struct WallpaperConfig: Codable, Equatable, Sendable {
    var enabled = false
    /// Wallpaper shown on every display without its own entry.
    var itemID: String?
    /// Display UUID -> item id. Empty means the same wallpaper everywhere.
    var perDisplay: [String: String] = [:]
    /// Item id -> fit override. Items without one use pixel-art mode when flagged, otherwise Fill.
    var fitOverrides: [String: WallpaperFit] = [:]
    /// Frame-rate cap for animated images: 15, 30 or 60.
    var frameRateCap = 30
    var pauseWhenCovered = true
    var pauseOnSaver = true
    /// Set the exported still as the system desktop picture so the lock screen and Spaces match.
    var syncLockScreen = true
    var playlistEnabled = false
    var playlistIDs: [String] = []
    var playlistMinutes = 15

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        func get<T: Decodable>(_ k: Keys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        enabled = get(.enabled, false)
        itemID = (try? c.decodeIfPresent(String.self, forKey: .itemID)) ?? nil
        perDisplay = get(.perDisplay, [:])
        fitOverrides = get(.fitOverrides, [:])
        frameRateCap = get(.frameRateCap, 30)
        pauseWhenCovered = get(.pauseWhenCovered, true)
        pauseOnSaver = get(.pauseOnSaver, true)
        syncLockScreen = get(.syncLockScreen, true)
        playlistEnabled = get(.playlistEnabled, false)
        playlistIDs = get(.playlistIDs, [])
        playlistMinutes = get(.playlistMinutes, 15)
    }
    private enum Keys: String, CodingKey {
        case enabled, itemID, perDisplay, fitOverrides, frameRateCap, pauseWhenCovered, pauseOnSaver
        case syncLockScreen, playlistEnabled, playlistIDs, playlistMinutes
    }
}

/// Contents of info.json.
struct WallpaperInfo: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String?
    var sourceURL: URL?
    var site: String
    var kind: WallpaperMediaKind
    var pixelWidth: Int
    var pixelHeight: Int
    var isPixelArt: Bool
    var added: Date
    var mediaFile: String

    var defaultFit: WallpaperFit { isPixelArt ? .pixelArt : .fill }
    var sizeText: String { "\(pixelWidth) × \(pixelHeight)" }
}

enum WallpaperLibraryError: Error, LocalizedError {
    case unreadable, unsupported
    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file could not be read."
        case .unsupported: return "Unsupported file type. Use an image, GIF, APNG, WebP, MP4, MOV or M4V."
        }
    }
}

@MainActor
@Observable
final class WallpaperLibrary {
    static let shared = WallpaperLibrary(root: SnapshotMode.active
        ? FileManager.default.temporaryDirectory.appendingPathComponent("HapticGlowSnapshotWallpapers", isDirectory: true)
        : WallpaperLibrary.defaultRoot)

    private(set) var items: [WallpaperInfo] = []
    let root: URL

    nonisolated static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HapticGlow/Wallpapers", isDirectory: true)
    }

    init(root: URL = WallpaperLibrary.defaultRoot) {
        self.root = root
        reload()
        // Snapshot mode shares UserDefaults with the real app, so it must not mark built-ins as seeded.
        if !SnapshotMode.active { seedBuiltIns() }
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func mediaURL(_ item: WallpaperInfo) -> URL { folder(item.id).appendingPathComponent(item.mediaFile) }
    func thumbURL(_ id: String) -> URL { folder(id).appendingPathComponent("thumb.jpg") }
    func stillURL(_ id: String) -> URL { folder(id).appendingPathComponent("still.png") }
    func item(_ id: String?) -> WallpaperInfo? { id.flatMap { i in items.first { $0.id == i } } }

    // MARK: Persistence

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [WallpaperInfo] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("info.json")),
                  let info = try? Self.decoder.decode(WallpaperInfo.self, from: data),
                  fm.fileExists(atPath: d.appendingPathComponent(info.mediaFile).path) else { continue }
            found.append(info)
        }
        items = found.sorted { $0.added > $1.added }
    }

    private func write(_ info: WallpaperInfo) throws {
        let data = try Self.encoder.encode(info)
        try data.write(to: folder(info.id).appendingPathComponent("info.json"), options: .atomic)
    }

    // MARK: Adding

    /// Copies a local file into the library. Image, GIF/APNG/WebP and video files are accepted.
    @discardableResult
    func importLocal(_ url: URL) async throws -> WallpaperInfo {
        let probe = try await Self.probe(url)
        return try await add(file: url, move: false, probe: probe, title: url.deletingPathExtension().lastPathComponent,
                             artist: nil, source: nil, site: "Local file", isPixelArt: nil)
    }

    /// Moves the importer's temporary file into the library.
    @discardableResult
    func add(imported: ImportedWallpaper) async throws -> WallpaperInfo {
        let probe = Probe(kind: imported.kind, width: imported.pixelWidth, height: imported.pixelHeight)
        return try await add(file: imported.fileURL, move: true, probe: probe, title: imported.title ?? imported.sourceURL.lastPathComponent,
                             artist: imported.artist, source: imported.sourceURL, site: imported.site, isPixelArt: imported.isPixelArt)
    }

    private func add(file: URL, move: Bool, probe: Probe, title: String, artist: String?, source: URL?, site: String,
                     isPixelArt: Bool?) async throws -> WallpaperInfo {
        let id = UUID().uuidString
        let dir = folder(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? (probe.kind == .video ? "mp4" : "png") : file.pathExtension.lowercased()
        let name = "media.\(ext)"
        let dest = dir.appendingPathComponent(name)
        do {
            if move { try? fm.removeItem(at: dest); try fm.moveItem(at: file, to: dest) } else { try fm.copyItem(at: file, to: dest) }
            guard let still = await Self.firstFrame(of: dest, kind: probe.kind, maxPixel: 4096) else { throw WallpaperLibraryError.unreadable }
            Self.writePNG(still, to: stillURL(id))
            if let thumb = Self.downsample(still, maxPixel: 480) { Self.writeJPEG(thumb, to: thumbURL(id)) }
            let pixel = isPixelArt ?? Self.looksLikePixelArt(width: probe.width, height: probe.height)
            let info = WallpaperInfo(id: id, title: title, artist: artist, sourceURL: source, site: site, kind: probe.kind,
                                     pixelWidth: probe.width, pixelHeight: probe.height, isPixelArt: pixel, added: Date(), mediaFile: name)
            try write(info)
            items.insert(info, at: 0)
            return info
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        items.removeAll { $0.id == id }
    }

    // MARK: Built-in wallpapers

    /// Original pixel-art loops bundled in Resources/DefaultWallpapers (generators in Tools/wallpapers).
    nonisolated static let builtIns: [(file: String, title: String)] = [
        ("harbor", "Dusk Harbor"), ("night-court", "Night Court"), ("arena", "Tip-Off"),
    ]
    private static let seededKey = "wallpaper.seededBuiltIns"
    nonisolated static func builtInID(_ file: String) -> String { "builtin-\(file)" }

    var missingBuiltIns: Bool { Self.builtIns.contains { item(Self.builtInID($0.file)) == nil } }

    /// Copies each bundled wallpaper in once. One the user deletes stays deleted until restoreBuiltIns().
    func seedBuiltIns(force: Bool = false) {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("DefaultWallpapers", isDirectory: true) else { return }
        let fm = FileManager.default
        var seeded = Set(UserDefaults.standard.stringArray(forKey: Self.seededKey) ?? [])
        for (i, b) in Self.builtIns.enumerated() where force || !seeded.contains(b.file) {
            let id = Self.builtInID(b.file)
            let src = dir.appendingPathComponent("\(b.file).gif")
            guard item(id) == nil, let source = CGImageSourceCreateWithURL(src as CFURL, nil),
                  let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { seeded.insert(b.file); continue }
            let dest = folder(id)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                try? fm.removeItem(at: dest.appendingPathComponent("media.gif"))
                try fm.copyItem(at: src, to: dest.appendingPathComponent("media.gif"))
                Self.writePNG(first, to: stillURL(id))
                if let big = Self.scaleNearest(first, by: 2) { Self.writeJPEG(big, to: thumbURL(id)) }
                // Older than anything the user adds, so imports stay at the top of the grid.
                let info = WallpaperInfo(id: id, title: b.title, artist: "Built-in", sourceURL: nil, site: "Built-in", kind: .animatedImage,
                                         pixelWidth: first.width, pixelHeight: first.height, isPixelArt: true,
                                         added: Date(timeIntervalSince1970: Double(Self.builtIns.count - i)), mediaFile: "media.gif")
                try write(info)
                seeded.insert(b.file)
            } catch {
                try? fm.removeItem(at: dest)
                Log.write("[wallpaper] built-in \(b.file) failed: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(Array(seeded).sorted(), forKey: Self.seededKey)
        reload()
    }

    func restoreBuiltIns() { seedBuiltIns(force: true) }

    nonisolated static func scaleNearest(_ image: CGImage, by k: Int) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: image.width * k, height: image.height * k, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width * k, height: image.height * k))
        return ctx.makeImage()
    }

    func setPixelArt(_ id: String, _ on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isPixelArt = on
        try? write(items[i])
    }

    /// Replace the exported still with a frame the user chose (a screenshot of the playing wallpaper).
    func setStill(_ id: String, _ image: CGImage) {
        Self.writePNG(image, to: stillURL(id))
        if let t = Self.downsample(image, maxPixel: 480) { Self.writeJPEG(t, to: thumbURL(id)) }
    }

    nonisolated static func looksLikePixelArt(width: Int, height: Int) -> Bool { max(width, height) <= 512 }

    // MARK: Probing and image helpers

    struct Probe: Sendable { var kind: WallpaperMediaKind; var width: Int; var height: Int }

    nonisolated static let videoExts: Set<String> = ["mp4", "mov", "m4v"]

    nonisolated static func probe(_ url: URL) async throws -> Probe {
        let ext = url.pathExtension.lowercased()
        if videoExts.contains(ext) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { throw WallpaperLibraryError.unreadable }
            let r = CGRect(origin: .zero, size: size).applying(transform)
            return Probe(kind: .video, width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()))
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw UTType(filenameExtension: ext) == nil ? WallpaperLibraryError.unsupported : WallpaperLibraryError.unreadable
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { throw WallpaperLibraryError.unreadable }
        return Probe(kind: CGImageSourceGetCount(src) > 1 ? .animatedImage : .image, width: w, height: h)
    }

    nonisolated static func firstFrame(of url: URL, kind: WallpaperMediaKind, maxPixel: Int) async -> CGImage? {
        if kind == .video {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try? await gen.image(at: .zero).image
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func downsample(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let m = max(image.width, image.height)
        guard m > maxPixel else { return image }
        let s = Double(maxPixel) / Double(m)
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }

    nonisolated static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    // MARK: Snapshot sample

    /// Screenshot mode only: three generated gradients so the grid has something to show.
    func installSample() {
        let names: [(String, UInt32, UInt32)] = [("Dusk", 0x2B1F4F, 0xE07A5F), ("Tide", 0x0B3C5D, 0x5FB3B3), ("Moss", 0x1F3B2D, 0xB8C77A)]
        for (i, n) in names.enumerated() {
            let id = "sample-\(i)"
            let dir = folder(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let img = Self.gradient(0xFF000000 | n.1, 0xFF000000 | n.2, w: 960, h: 540) else { continue }
            Self.writePNG(img, to: dir.appendingPathComponent("media.png"))
            Self.writePNG(img, to: stillURL(id))
            Self.writeJPEG(img, to: thumbURL(id))
            let info = WallpaperInfo(id: id, title: n.0, artist: i == 0 ? "Generated" : nil, sourceURL: nil, site: "Sample",
                                     kind: .image, pixelWidth: 960, pixelHeight: 540, isPixelArt: false,
                                     added: Date().addingTimeInterval(Double(-i)), mediaFile: "media.png")
            try? write(info)
        }
        reload()
    }

    nonisolated static func gradient(_ a: UInt32, _ b: UInt32, w: Int, h: Int) -> CGImage? {
        func comps(_ v: UInt32) -> [CGFloat] { [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255, 1] }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let g = CGGradient(colorSpace: cs, colorComponents: comps(a) + comps(b), locations: [0, 1], count: 2),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        return ctx.makeImage()
    }
}
