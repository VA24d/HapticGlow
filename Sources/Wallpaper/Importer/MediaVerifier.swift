// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import AVFoundation
import Foundation
import ImageIO

struct VerifiedMedia: Sendable {
    var fileURL: URL
    var kind: WallpaperMediaKind
    var width: Int
    var height: Int
    var looksPixelArt: Bool
}

/// Sniffs a downloaded file, gives it a correct extension, and checks it decodes with ImageIO or AVFoundation.
enum MediaVerifier {
    private enum Sniffed { case image(String), video(String), unsupported }

    static func verify(_ file: URL) async throws -> VerifiedMedia {
        let head = (try? FileHandle(forReadingFrom: file).read(upToCount: 32)) ?? Data()
        let b = [UInt8](head)
        let ext: String
        switch sniff(b) {
        case .unsupported: throw WallpaperImportError.invalidMedia
        case .image(let e), .video(let e): ext = e
        }
        let target = file.deletingLastPathComponent().appendingPathComponent("media.\(ext)")
        if file != target {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: file, to: target)
        }
        do {
            if case .video = sniff(b) { return try await verifyVideo(target) }
            return try verifyImage(target)
        } catch {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            throw error
        }
    }

    private static func sniff(_ b: [UInt8]) -> Sniffed {
        func starts(_ s: String, at o: Int = 0) -> Bool {
            let u = Array(s.utf8)
            return b.count >= o + u.count && Array(b[o..<(o + u.count)]) == u
        }
        if starts("GIF8") { return .image("gif") }
        if b.count > 3, b[0] == 0x89, starts("PNG", at: 1) { return .image("png") }
        if b.count > 3, b[0] == 0xFF, b[1] == 0xD8 { return .image("jpg") }
        if starts("RIFF"), starts("WEBP", at: 8) { return .image("webp") }
        if starts("BM") { return .image("bmp") }
        if starts("II*") || starts("MM") { return .image("tiff") }
        if starts("ftyp", at: 4) {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") || brand.hasPrefix("avif") {
                return .image(brand.hasPrefix("avif") ? "avif" : "heic")
            }
            return .video(brand.hasPrefix("qt") ? "mov" : "mp4")
        }
        return .unsupported // includes WebM/Matroska, HTML error pages, and anything unknown
    }

    private static func verifyImage(_ url: URL) throws -> VerifiedMedia {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw WallpaperImportError.invalidMedia }
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let frames = CGImageSourceGetCount(src)
        var pixel = false
        if let first = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
            pixel = PixelArtHeuristic.looksLikePixelArt(first)
        }
        return VerifiedMedia(fileURL: url, kind: frames > 1 ? .animatedImage : .image, width: w, height: h, looksPixelArt: pixel)
    }

    private static func verifyVideo(_ url: URL) async throws -> VerifiedMedia {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw WallpaperImportError.invalidMedia
            }
            let (size, xf) = try await track.load(.naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: size).applying(xf)
            let w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
            guard w > 0, h > 0 else { throw WallpaperImportError.invalidMedia }
            return VerifiedMedia(fileURL: url, kind: .video, width: w, height: h, looksPixelArt: false)
        } catch let e as WallpaperImportError {
            throw e
        } catch {
            throw WallpaperImportError.invalidMedia
        }
    }
}

/// Cheap check on one frame: few distinct colours and mostly flat horizontal runs (hard edges, no anti-aliasing).
enum PixelArtHeuristic {
    static func looksLikePixelArt(_ image: CGImage) -> Bool {
        // A centre crop keeps pixels exact and bounds the work to ~1M pixels.
        let cw = min(image.width, 1024), ch = min(image.height, 1024)
        guard cw >= 8, ch >= 8,
              let crop = image.cropping(to: CGRect(x: (image.width - cw) / 2, y: (image.height - ch) / 2, width: cw, height: ch))
        else { return false }
        var buf = [UInt8](repeating: 0, count: cw * ch * 4)
        let drawn: Bool = buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            return true
        }
        guard drawn else { return false }
        var colors = Set<UInt32>()
        var same = 0, pairs = 0
        let rowStep = max(1, ch / 256)
        var y = 0
        while y < ch {
            var prev: UInt32 = 0
            for x in 0..<cw {
                let i = (y * cw + x) * 4
                let c = UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2])
                colors.insert(c)
                if colors.count > 128 { return false }
                if x > 0 { pairs += 1; if c == prev { same += 1 } }
                prev = c
            }
            y += rowStep
        }
        return colors.count >= 2 && pairs > 0 && Double(same) / Double(pairs) >= 0.55
    }
}
