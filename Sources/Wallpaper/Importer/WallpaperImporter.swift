// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import Foundation

/// Temporary stub, replaced by the real importer on merge.
enum WallpaperImporter {
    static func importMedia(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ImportedWallpaper {
        throw WallpaperImportError.unsupportedSite
    }
}
