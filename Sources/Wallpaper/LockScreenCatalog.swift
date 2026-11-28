// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Pure editing of an Aerial catalog (entries.json): add, replace and remove HapticGlow entries.
import Foundation
import CryptoKit

enum LockScreenCatalog {
    /// Fallback: system folder the Aerial agent reads custom entries from (needs administrator rights).
    static let customerPath = "/Library/Application Support/com.apple.idleassetsd/Customer"
    static let videoFolder = "4KSDR240FPS"
    static let previewFolder = "snapshots"
    /// Fixed ids so every install lands in the same "HapticGlow" category and can be found again.
    static let categoryID = "6C0E4A1B-5D2F-4F7A-9B3C-8A1D2E3F4A5B"
    static let subcategoryID = "A3F1C7D2-8E4B-4B6A-9C5D-1E2F3A4B5C6D"
    static let shotPrefix = "HAPTICGLOW_"

    struct Asset: Equatable {
        var id: String          // stable UUID of the library item, see `assetID(for:)`
        var title: String
    }

    /// Where the video and preview of an entry are read from (file:// URLs).
    struct Links { var video: String; var preview: String }

    enum CatalogError: Error, LocalizedError {
        case malformed, unexpectedSchema(String)
        var errorDescription: String? {
            switch self {
            case .malformed: return "The existing Aerial catalog (entries.json) is not in the expected format, so nothing was changed."
            case .unexpectedSchema(let why): return "The Aerial catalog has a layout this version of HapticGlow does not know (\(why)), so nothing was changed."
            }
        }
    }

    /// Stable, name-based UUID (version 5 layout) so one library item always maps to one lock-screen entry.
    static func assetID(for itemID: String) -> String {
        var b = Array(SHA256.hash(data: Data(("HapticGlow.lockscreen:" + itemID).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    static func fileURL(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }

    /// System (admin) layout.
    static func systemLinks(_ id: String) -> Links {
        Links(video: fileURL("\(customerPath)/\(videoFolder)/\(id).mov"), preview: fileURL("\(customerPath)/\(previewFolder)/\(id).jpg"))
    }

    private typealias JSON = [String: Any]

    private static func parse(_ data: Data?) throws -> JSON {
        guard let data, !data.isEmpty else {
            return ["assets": [JSON](), "categories": [JSON](), "initialAssetCount": 0, "localizationVersion": "1", "version": 1]
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw CatalogError.malformed }
        return o
    }

    private static func isOurs(_ asset: JSON) -> Bool {
        ((asset["categories"] as? [String]) ?? []).contains(categoryID) || ((asset["shotID"] as? String) ?? "").hasPrefix(shotPrefix)
    }

    private static func encode(_ o: JSON) throws -> Data {
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// An Apple asset whose layout is copied: it has a 4K URL, is not grouped, and preferably has no variant.
    private static func template(in assets: [JSON]) -> JSON? {
        let ok = assets.filter { !isOurs($0) && ($0["url-4K-SDR-240FPS"] as? String) != nil && $0["group"] == nil }
        return ok.first(where: { $0["variant"] == nil }) ?? ok.first
    }

    /// Strict check of the user-level catalog before anything is written: version 1, assets and categories lists with
    /// string ids, and at least one Apple asset to copy the field layout from.
    static func checkUserSchema(_ data: Data) throws {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw CatalogError.malformed }
        guard (o["version"] as? Int) == 1 else { throw CatalogError.unexpectedSchema("version \(o["version"].map { "\($0)" } ?? "missing")") }
        guard let assets = o["assets"] as? [JSON], !assets.isEmpty else { throw CatalogError.unexpectedSchema("no assets list") }
        guard let cats = o["categories"] as? [JSON], !cats.isEmpty else { throw CatalogError.unexpectedSchema("no categories list") }
        guard assets.allSatisfy({ $0["id"] is String }), cats.allSatisfy({ $0["id"] is String }) else { throw CatalogError.unexpectedSchema("entries without ids") }
        guard template(in: assets) != nil else { throw CatalogError.unexpectedSchema("no asset with a 4K video URL") }
    }

    /// Ids of HapticGlow entries already in the catalog.
    static func installedIDs(in data: Data?) -> [String] {
        guard let o = try? parse(data), let assets = o["assets"] as? [JSON] else { return [] }
        return assets.filter(isOurs).compactMap { $0["id"] as? String }
    }

    /// Adds or replaces `asset` (and the HapticGlow category). Every entry that is not ours is kept as it was.
    static func adding(_ asset: Asset, to data: Data?, links: Links) throws -> Data {
        var o = try parse(data)
        guard o["assets"] == nil || o["assets"] is [JSON], o["categories"] == nil || o["categories"] is [JSON] else { throw CatalogError.malformed }
        var assets = (o["assets"] as? [JSON]) ?? []
        var categories = (o["categories"] as? [JSON]) ?? []
        var entry: JSON = [
            "id": asset.id,
            "accessibilityLabel": asset.title,
            "localizedNameKey": asset.title,
            "shotID": shotPrefix + asset.id.prefix(8),
            "includeInShuffle": false,
            "showInTopLevel": true,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "pointsOfInterest": JSON(),
            "previewImage": links.preview,
            "url-4K-SDR-240FPS": links.video,
            "videoGravity": "resize",
        ]
        // Mirror an Apple asset: only keys it also has (a variant or group would tie us to Apple's own grouping).
        if let t = template(in: assets) { entry = entry.filter { t[$0.key] != nil } }
        if let i = assets.firstIndex(where: { ($0["id"] as? String) == asset.id }) { assets[i] = entry } else { assets.append(entry) }
        let ours = assets.filter(isOurs)
        let preview = (ours.first?["previewImage"] as? String) ?? links.preview
        let rep = (ours.first?["id"] as? String) ?? asset.id
        let cat: JSON = [
            "id": categoryID,
            "localizedNameKey": "HapticGlow",
            "localizedDescriptionKey": "HapticGlow",
            "preferredOrder": -1,
            "previewImage": preview,
            "representativeAssetID": rep,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "HapticGlow",
                "localizedDescriptionKey": "HapticGlow",
                "preferredOrder": 0,
                "combineVariants": true,
                "previewImage": preview,
                "representativeAssetID": rep,
            ] as JSON],
        ]
        if let i = categories.firstIndex(where: { ($0["id"] as? String) == categoryID }) { categories[i] = cat } else { categories.append(cat) }
        o["assets"] = assets
        o["categories"] = categories
        return try encode(o)
    }

    /// Drops every HapticGlow entry and the HapticGlow category, leaving all other entries untouched.
    static func removingOurs(from data: Data?) throws -> (data: Data, removedIDs: [String]) {
        var o = try parse(data)
        guard o["assets"] == nil || o["assets"] is [JSON], o["categories"] == nil || o["categories"] is [JSON] else { throw CatalogError.malformed }
        let assets = (o["assets"] as? [JSON]) ?? []
        let removed = assets.filter(isOurs).compactMap { $0["id"] as? String }
        let kept = assets.filter { !isOurs($0) }
        o["assets"] = kept
        o["categories"] = ((o["categories"] as? [JSON]) ?? []).filter { ($0["id"] as? String) != categoryID }
        return (try encode(o), removed)
    }
}
