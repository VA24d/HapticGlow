// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import Foundation

enum WallpaperMediaKind: String, Codable, Sendable { case image, animatedImage, video }

/// Result of importing media from a web page or direct link. `fileURL` is a temporary file the caller moves into the library.
struct ImportedWallpaper: Sendable {
    var fileURL: URL
    var kind: WallpaperMediaKind
    var pixelWidth: Int
    var pixelHeight: Int
    var title: String?
    var artist: String?
    var sourceURL: URL
    var site: String
    var isPixelArt: Bool
}

enum WallpaperImportError: Error, Sendable { case unsupportedSite, notFound, needsLogin, network(String), invalidMedia }
