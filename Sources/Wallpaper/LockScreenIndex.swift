// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Pure editing of the wallpaper store (Store/Index.plist): point the `Idle` (screen saver / lock screen) choice at a still picture, and put it back.
import Foundation

enum LockScreenIndex {
    typealias Dict = [String: Any]

    static let imageProvider = "com.apple.wallpaper.choice.image"
    /// Every still HapticGlow sets lives in a folder with this name, which is how our own choices are recognised.
    static let stillsFolderName = "LockScreenStills"

    enum IndexError: Error, LocalizedError {
        case unreadable, noTemplate
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The wallpaper settings file is not in a layout this version of HapticGlow knows."
            case .noTemplate: return "The wallpaper settings hold no picture choice to copy the layout from."
            }
        }
    }

    // MARK: Reading and writing the file

    static func decode(_ data: Data) throws -> (root: Dict, format: PropertyListSerialization.PropertyListFormat) {
        var fmt = PropertyListSerialization.PropertyListFormat.binary
        guard let o = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt) as? Dict else { throw IndexError.unreadable }
        return (o, fmt)
    }

    static func encode(_ root: Dict, format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
    }

    // MARK: Finding nodes

    /// Key paths of every `Idle` node that holds a `Content` dictionary (all Spaces, displays and the defaults).
    static func idlePaths(_ root: Dict) -> [[String]] {
        var out: [[String]] = []
        func walk(_ d: Dict, _ path: [String]) {
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                guard let child = v as? Dict else { continue }
                if k == "Idle", child["Content"] is Dict { out.append(path + [k]) } else { walk(child, path + [k]) }
            }
        }
        walk(root, [])
        return out
    }

    private static func node(_ root: Dict, _ path: [String]) -> Dict? {
        var cur: Any = root
        for k in path { guard let d = cur as? Dict, let n = d[k] else { return nil }; cur = n }
        return cur as? Dict
    }

    private static func setNode(_ root: inout Dict, _ path: [String], _ value: Dict) {
        guard let k = path.first else { return }
        if path.count == 1 { root[k] = value; return }
        var child = (root[k] as? Dict) ?? [:]
        setNode(&child, Array(path.dropFirst()), value)
        root[k] = child
    }

    private static func choice(_ content: Dict) -> Dict? { (content["Choices"] as? [Dict])?.first }

    private static func config(_ choice: Dict) -> Dict? {
        guard let b = choice["Configuration"] as? Data, !b.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: b, options: [], format: nil)) as? Dict
    }

    private static func stillURL(of content: Dict) -> String? {
        guard let c = choice(content), (c["Provider"] as? String) == imageProvider,
              let cfg = config(c), let url = cfg["url"] as? Dict else { return nil }
        return url["relative"] as? String
    }

    static func isOurs(content: Dict) -> Bool { (stillURL(of: content) ?? "").contains("/\(stillsFolderName)/") }

    /// Number of `Idle` nodes that currently show one of our stills.
    static func ourIdleCount(_ root: Dict) -> Int {
        idlePaths(root).filter { p in (node(root, p)?["Content"] as? Dict).map(isOurs) ?? false }.count
    }

    // MARK: Setting a still

    /// Copies the layout of a picture choice already in the file (the Desktop one next to each Idle node, else any),
    /// points it at `url`, and uses it as the `Idle` content. Everything else in the file stays as it was.
    /// Returns the new root and how many Idle nodes changed.
    static func settingStill(_ url: URL, in root: Dict, now: Date = Date()) throws -> (root: Dict, changed: Int) {
        let paths = idlePaths(root)
        guard !paths.isEmpty else { throw IndexError.unreadable }
        func template(for idle: [String]) -> Dict? {
            let sibling = Array(idle.dropLast()) + ["Desktop"]
            if let c = node(root, sibling)?["Content"] as? Dict, stillURL(of: c) != nil { return c }
            return nil
        }
        func anyTemplate() -> Dict? {
            func find(_ d: Dict) -> Dict? {
                for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                    guard let child = v as? Dict else { continue }
                    if k == "Desktop", let c = child["Content"] as? Dict, stillURL(of: c) != nil { return c }
                    if let f = find(child) { return f }
                }
                return nil
            }
            return find(root)
        }
        let fallback = anyTemplate()
        var out = root, changed = 0
        for p in paths {
            guard let base = template(for: p) ?? fallback, var ch = choice(base), var cfg = config(ch), var u = cfg["url"] as? Dict else { continue }
            u["relative"] = url.absoluteString
            cfg["url"] = u
            ch["Configuration"] = try PropertyListSerialization.data(fromPropertyList: cfg, format: .binary, options: 0)
            ch["Files"] = [Any]()
            var content = base
            content["Choices"] = [ch]
            var n = node(out, p) ?? [:]
            n["Content"] = content
            n["LastSet"] = now
            n["LastUse"] = now
            setNode(&out, p, n)
            changed += 1
        }
        guard changed > 0 else { throw IndexError.noTemplate }
        return (out, changed)
    }

    /// True when the file has a picture choice to copy the layout from.
    static func hasTemplate(_ root: Dict) -> Bool {
        (try? settingStill(URL(fileURLWithPath: "/x.png"), in: root)) != nil
    }

    // MARK: Restoring

    /// Puts back every Idle node that shows one of our stills: from `backup` when it has that node and it is not ours,
    /// else macOS's own default screen saver choice. Returns the new root and how many nodes were restored.
    static func restoring(_ root: Dict, from backup: Dict?) -> (root: Dict, restored: Int) {
        var out = root, n = 0
        for p in idlePaths(root) {
            guard let cur = node(root, p), let content = cur["Content"] as? Dict, isOurs(content: content) else { continue }
            var repl = cur
            if let b = backup.flatMap({ node($0, p) }), let bc = b["Content"] as? Dict, !isOurs(content: bc) {
                repl = b
            } else {
                repl["Content"] = defaultIdleContent()
            }
            setNode(&out, p, repl)
            n += 1
        }
        return (out, n)
    }

    /// The content macOS writes for the default screen saver choice (as found in the file on a fresh setup).
    static func defaultIdleContent() -> Dict {
        let empty = (try? PropertyListSerialization.data(fromPropertyList: ["values": Dict()], format: .binary, options: 0)) ?? Data()
        return ["Choices": [["Configuration": Data(), "Files": [Any](), "Provider": "com.apple.NeptuneOneExtension"] as Dict],
                "EncodedOptionValues": empty, "Shuffle": "$null"]
    }
}
