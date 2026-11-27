// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import Foundation

extension WallpaperImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSite: return "That link is not one HapticGlow can import from. Paste a page link or a direct image or video link."
        case .notFound: return "No downloadable image or video was found at that link. It may have been removed."
        case .needsLogin: return "This item needs a login to view. HapticGlow only imports media that a logged-out visitor can see."
        case .network(let m): return "The download failed. \(m)"
        case .invalidMedia: return "The file at that link is not an image or video HapticGlow can use."
        }
    }
}

/// Imports a wallpaper from a page link or direct media link, taking the best quality the site shows publicly.
/// Only logged-out requests are made: no cookies, no accounts, no paywall or watermark handling.
enum WallpaperImporter {
    static func importMedia(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedWallpaper {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw WallpaperImportError.unsupportedSite
        }
        progress(0)
        let host = (url.host ?? "").lowercased()
        func on(_ d: String) -> Bool { host == d || host.hasSuffix("." + d) }

        let plan: ImportPlan
        if on("deviantart.com") || on("fav.me") {
            plan = try await ImportResolvers.deviantArt(url)
        } else if on("artstation.com") {
            plan = try await ImportResolvers.artStation(url)
        } else if on("reddit.com") || host == "redd.it" {
            plan = try await ImportResolvers.reddit(url)
        } else if on("imgur.com") {
            plan = try await ImportResolvers.generic(url, siteOverride: "Imgur")
        } else {
            plan = try await ImportResolvers.generic(url)
        }
        progress(0.05)

        var firstError: Error?
        for (i, candidate) in plan.candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let res: FetchedResource
                if i == 0, let pre = plan.preFetched { res = pre }
                else {
                    res = try await ImportNet.fetch(candidate, accept: "image/*,video/*;q=0.9,*/*;q=0.5") { f in
                        progress(0.05 + 0.9 * f)
                    }
                }
                guard case .file(let file) = res.body else { throw WallpaperImportError.invalidMedia }
                let v = try await MediaVerifier.verify(file)
                progress(1)
                let tagText = (plan.tags + [plan.title ?? ""]).joined(separator: " ").lowercased()
                let pixel = tagText.contains("pixel") || v.looksPixelArt
                return ImportedWallpaper(
                    fileURL: v.fileURL, kind: v.kind, pixelWidth: v.width, pixelHeight: v.height,
                    title: plan.title, artist: plan.artist, sourceURL: url, site: plan.site, isPixelArt: pixel)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? WallpaperImportError.notFound
    }
}
