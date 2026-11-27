// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import Foundation

/// Small HTML helpers for meta-tag scraping.
enum ImportHTML {
    private static let entityRE = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    private static let metaRE = try! NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive])
    private static let attrRE = try! NSRegularExpression(
        pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
    private static let titleRE = try! NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: [.caseInsensitive])

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entityRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            var rep: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                rep = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                rep = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                rep = named[body.lowercased()]
            }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// All `<meta>` tags as (key, content), key lower-cased, content entity-decoded.
    static func metaTags(_ html: String) -> [(key: String, content: String)] {
        let ns = html as NSString
        var result: [(key: String, content: String)] = []
        for m in metaRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let tns = tag as NSString
            var attrs: [String: String] = [:]
            for a in attrRE.matches(in: tag, range: NSRange(location: 0, length: tns.length)) {
                let name = tns.substring(with: a.range(at: 1)).lowercased()
                let g = a.range(at: 2).location != NSNotFound ? a.range(at: 2) : a.range(at: 3)
                attrs[name] = tns.substring(with: g)
            }
            if let key = attrs["property"] ?? attrs["name"] ?? attrs["itemprop"], let c = attrs["content"] {
                result.append((key.lowercased(), decodeEntities(c).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return result
    }

    static func titleTag(_ html: String) -> String? {
        let ns = html as NSString
        guard let m = titleRE.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let t = decodeEntities(ns.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Entity-decodes and resolves a (possibly relative) URL string.
    static func resolve(_ s: String, base: URL) -> URL? {
        let d = decodeEntities(s).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, let u = URL(string: d, relativeTo: base)?.absoluteURL,
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }
}

extension URL {
    var importExtension: String { pathExtension.lowercased() }
    var isLikelyVideoFile: Bool { ["mp4", "mov", "m4v"].contains(importExtension) }
    var isLikelyMediaFile: Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v", "gifv"].contains(importExtension)
    }
}
