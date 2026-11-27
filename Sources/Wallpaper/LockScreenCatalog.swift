// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Pure editing of the Aerial catalog (idleassetsd Customer/entries.json): add, replace and remove HapticGlow entries.
import Foundation
import CryptoKit

enum LockScreenCatalog {
    /// System folder the Aerial agent reads custom entries from.
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

    enum CatalogError: Error, LocalizedError {
        case malformed
        var errorDescription: String? { "The existing Aerial catalog (entries.json) is not in the expected format, so nothing was changed." }
    }

    /// Stable, name-based UUID (version 5 layout) so one library item always maps to one lock-screen entry.
    static func assetID(for itemID: String) -> String {
        var b = Array(SHA256.hash(data: Data(("HapticGlow.lockscreen:" + itemID).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString
    }

    static func videoURL(_ id: String) -> String { "file://" + customerPath.replacingOccurrences(of: " ", with: "%20") + "/\(videoFolder)/\(id).mov" }
    static func previewURL(_ id: String) -> String { "file://" + customerPath.replacingOccurrences(of: " ", with: "%20") + "/\(previewFolder)/\(id).jpg" }

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

    /// Ids of HapticGlow entries already in the catalog.
    static func installedIDs(in data: Data?) -> [String] {
        guard let o = try? parse(data), let assets = o["assets"] as? [JSON] else { return [] }
        return assets.filter(isOurs).compactMap { $0["id"] as? String }
    }

    /// Adds or replaces `asset` (and the HapticGlow category). Every entry that is not ours is kept as it was.
    static func adding(_ asset: Asset, to data: Data?) throws -> Data {
        var o = try parse(data)
        var assets = (o["assets"] as? [JSON]) ?? []
        var categories = (o["categories"] as? [JSON]) ?? []
        guard o["assets"] == nil || o["assets"] is [JSON], o["categories"] == nil || o["categories"] is [JSON] else { throw CatalogError.malformed }
        let entry: JSON = [
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
            "previewImage": previewURL(asset.id),
            "url-4K-SDR-240FPS": videoURL(asset.id),
            "videoGravity": "resize",
        ]
        if let i = assets.firstIndex(where: { ($0["id"] as? String) == asset.id }) { assets[i] = entry } else { assets.append(entry) }
        let ours = assets.filter(isOurs)
        let cat: JSON = [
            "id": categoryID,
            "localizedNameKey": "HapticGlow",
            "localizedDescriptionKey": "HapticGlow",
            "preferredOrder": 100,
            "previewImage": (ours.first?["previewImage"] as? String) ?? previewURL(asset.id),
            "representativeAssetID": (ours.first?["id"] as? String) ?? asset.id,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "HapticGlow",
                "localizedDescriptionKey": "HapticGlow",
                "preferredOrder": 0,
                "previewImage": (ours.first?["previewImage"] as? String) ?? previewURL(asset.id),
                "representativeAssetID": (ours.first?["id"] as? String) ?? asset.id,
            ] as JSON],
        ]
        if let i = categories.firstIndex(where: { ($0["id"] as? String) == categoryID }) { categories[i] = cat } else { categories.append(cat) }
        o["assets"] = assets
        o["categories"] = categories
        o["initialAssetCount"] = assets.count
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
        o["initialAssetCount"] = kept.count
        return (try encode(o), removed)
    }
}
