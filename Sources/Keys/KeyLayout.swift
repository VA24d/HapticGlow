// MacBook Pro (14"/16" Apple Silicon) and MacBook Air (M1 / M2+) ANSI keyboard geometry.
// Rects are in key units (1u ≈ 19.05 mm pitch, 14.5u wide), origin top-left.
// Virtual keycodes are the Carbon kVK_* values.
import Foundation
import CoreGraphics
import IOKit

enum MacKeyboardKind: String, Sendable {
    /// MacBook Pro 14" / 16" (Apple Silicon): 14.5u, full-height function row, 1u Touch ID, black recessed well, 4 half-height inverted-T arrows.
    case macBookPro
    /// MacBook Air 13" / 15" (M2+): 14.5u, full-height function row, 1u Touch ID, body-colored deck, 4 half-height inverted-T arrows.
    case macBookAir
    /// MacBook Air 13" (M1, 2020): 14.5u, half-height function row, half-height Touch ID, body-colored deck, 4 half-height inverted-T arrows.
    case macBookAirM1
}

enum KeyLayout {
    /// Raw `hw.model` from sysctl (e.g. "Mac17,9").
    static let hardwareModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }()

    /// Human-readable product name from IORegistry `IODeviceTree:/product` (e.g. "MacBook Pro (14-inch, M5 Pro)").
    static let productName: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != IO_OBJECT_NULL else { return "" }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return ""
        }
        if let data = prop as? Data {
            let trimmed = data.prefix { $0 != 0 }
            return String(data: trimmed, encoding: .utf8) ?? ""
        }
        return (prop as? String) ?? ""
    }()

    /// Detected built-in MacBook keyboard layout kind.
    static let kind: MacKeyboardKind = detectKind(hardwareModel: hardwareModel, productName: productName)

    static func detectKind(hardwareModel model: String, productName product: String) -> MacKeyboardKind {
        let lowerProduct = product.lowercased()
        let lowerModel = model.lowercased()
        if lowerProduct.contains("macbook air") {
            if model == "MacBookAir10,1" || lowerProduct.contains("(m1") || lowerProduct.contains(" m1") {
                return .macBookAirM1
            }
            return .macBookAir
        }
        if lowerProduct.contains("macbook pro") {
            return .macBookPro
        }
        if model == "MacBookAir10,1" { return .macBookAirM1 }
        if lowerModel.hasPrefix("macbookair") || airModels.contains(model) {
            return .macBookAir
        }
        return .macBookPro
    }

    private static let airModels: Set<String> = [
        "Mac14,2", "Mac14,15",   // M2 Air 13", 15"
        "Mac15,12", "Mac15,13",  // M3 Air 13", 15"
        "Mac16,12", "Mac16,13",  // M4 Air 13", 15"
        "Mac17,3", "Mac17,4",    // M5 Air 13", 15"
    ]

    /// (keyCode, label, width, kind) specs per row, left to right (each row sums to 14.5u).
    private typealias Spec = (code: UInt16, label: String, w: CGFloat, kind: KeyKind)

    private static func g(_ c: UInt16, _ l: String, _ w: CGFloat = 1) -> Spec { (c, l, w, .generic) }
    private static func m(_ c: UInt16, _ l: String, _ w: CGFloat = 1) -> Spec { (c, l, w, .modifier) }
    private static func f(_ c: UInt16, _ l: String) -> Spec { (c, l, 1, .function) }

    private static let rows: [[Spec]] = [
        // 0: function row (1.5 + 12*1 + 1 = 14.5u)
        [(53, "esc", 1.5, .escape),
         f(122, "F1"), f(120, "F2"), f(99, "F3"), f(118, "F4"), f(96, "F5"), f(97, "F6"),
         f(98, "F7"), f(100, "F8"), f(101, "F9"), f(109, "F10"), f(103, "F11"), f(111, "F12"),
         (0xFFFF, "", 1.0, .function)],
        // 1: number row (13*1 + 1.5 = 14.5u)
        [g(50, "`"), g(18, "1"), g(19, "2"), g(20, "3"), g(21, "4"), g(23, "5"), g(22, "6"),
         g(26, "7"), g(28, "8"), g(25, "9"), g(29, "0"), g(27, "-"), g(24, "="),
         (51, "delete", 1.5, .backspace)],
        // 2: tab row (1.5 + 12*1 + 1 = 14.5u)
        [(48, "tab", 1.5, .tab),
         g(12, "Q"), g(13, "W"), g(14, "E"), g(15, "R"), g(17, "T"), g(16, "Y"), g(32, "U"),
         g(34, "I"), g(31, "O"), g(35, "P"), g(33, "["), g(30, "]"), g(42, "\\", 1.0)],
        // 3: caps row (1.75 + 11*1 + 1.75 = 14.5u)
        [(57, "caps", 1.75, .capsLock),
         g(0, "A"), g(1, "S"), g(2, "D"), g(3, "F"), g(5, "G"), g(4, "H"), g(38, "J"),
         g(40, "K"), g(37, "L"), g(41, ";"), g(39, "'"),
         (36, "return", 1.75, .enter)],
        // 4: shift row (2.25 + 10*1 + 2.25 = 14.5u)
        [m(56, "shift", 2.25),
         g(6, "Z"), g(7, "X"), g(8, "C"), g(9, "V"), g(11, "B"), g(45, "N"), g(46, "M"),
         g(43, ","), g(47, "."), g(44, "/"),
         m(60, "shift", 2.25)],
    ]

    static func fnRowHeight(for kind: MacKeyboardKind) -> CGFloat {
        kind == .macBookAirM1 ? 0.58 : 1.0
    }

    static func buildCaps(for kind: MacKeyboardKind) -> [KeyCap] {
        let fnH = fnRowHeight(for: kind)
        var out: [KeyCap] = []
        out.reserveCapacity(78)
        var id = 0
        var y: CGFloat = 0
        for (r, specs) in rows.enumerated() {
            let h: CGFloat = r == 0 ? fnH : 1.0
            var x: CGFloat = 0
            for s in specs {
                out.append(KeyCap(id: id, keyCode: s.code, label: s.label,
                                  rect: CGRect(x: x, y: y, width: s.w, height: h), kind: s.kind, row: r))
                id += 1; x += s.w
            }
            y += h
        }
        // Row 5 (1 + 1 + 1 + 1.25 + 5 + 1.25 + 1 + 3 = 14.5u): fn ctrl opt cmd space cmd opt + inverted-T half-height arrows
        var x: CGFloat = 0
        func add(_ code: UInt16, _ label: String, _ w: CGFloat, _ kind: KeyKind,
                 dy: CGFloat = 0, h: CGFloat = 1, dx: CGFloat? = nil) {
            out.append(KeyCap(id: id, keyCode: code, label: label,
                              rect: CGRect(x: dx ?? x, y: y + dy, width: w, height: h), kind: kind, row: 5))
            id += 1
            if dx == nil { x += w }
        }
        add(63, "fn", 1, .fn)
        add(59, "control", 1, .modifier)
        add(58, "option", 1, .modifier)
        add(55, "command", 1.25, .modifier)
        add(49, "", 5.0, .space)
        add(54, "command", 1.25, .modifier)
        add(61, "option", 1, .modifier)
        let ax = x
        add(123, "◀", 1, .arrow, dy: 0.5, h: 0.5, dx: ax)
        add(126, "▲", 1, .arrow, dy: 0.0, h: 0.5, dx: ax + 1)
        add(125, "▼", 1, .arrow, dy: 0.5, h: 0.5, dx: ax + 1)
        add(124, "▶", 1, .arrow, dy: 0.5, h: 0.5, dx: ax + 2)
        return out
    }

    static func boardSize(for kind: MacKeyboardKind) -> CGSize {
        CGSize(width: 14.5, height: 5.0 + fnRowHeight(for: kind))
    }

    private static let capsByKind: [MacKeyboardKind: [KeyCap]] = [
        .macBookPro: buildCaps(for: .macBookPro),
        .macBookAir: buildCaps(for: .macBookAir),
        .macBookAirM1: buildCaps(for: .macBookAirM1),
    ]

    static func caps(for kind: MacKeyboardKind) -> [KeyCap] {
        capsByKind[kind] ?? caps
    }

    /// All keycaps for the detected Mac model.
    static let caps: [KeyCap] = capsByKind[kind] ?? buildCaps(for: kind)

    /// Overall board size in key units for the detected Mac model.
    static let size: CGSize = boardSize(for: kind)

    private static let byCode: [UInt16: KeyCap] = {
        var d: [UInt16: KeyCap] = [:]
        for c in caps where c.keyCode != 0xFFFF { d[c.keyCode] = c }
        return d
    }()

    static func cap(for keyCode: UInt16) -> KeyCap? { byCode[keyCode] }

    private struct Entry { var x: Float; var y: Float; var row: Int8; var kind: KeyKind; var known: Bool }

    /// Flat 256-entry table so lookups on the key-event thread are one array read.
    private static let table: [Entry] = {
        var t = [Entry](repeating: Entry(x: 0.5, y: 0.5, row: 3, kind: .generic, known: false), count: 256)
        let sz = size
        func put(_ code: UInt16, _ r: CGRect, _ row: Int, _ kind: KeyKind) {
            guard code < 256 else { return }
            t[Int(code)] = Entry(x: Float(r.midX / sz.width), y: Float(r.midY / sz.height),
                                 row: Int8(row), kind: kind, known: true)
        }
        for c in caps where c.keyCode != 0xFFFF { put(c.keyCode, c.rect, c.row, c.kind) }
        // Extras not on the MacBook board: map near their closest analogue.
        if let del = byCode[51] { put(117, del.rect, 1, .backspace) }          // forward delete
        if let ret = byCode[36] { put(76, ret.rect, 3, .enter) }               // keypad enter
        if let ctl = byCode[59] { put(62, CGRect(x: sz.width - 3.5, y: ctl.rect.minY, width: 1, height: 1), 5, .modifier) } // right control
        if let fnKey = byCode[63] { put(179, fnKey.rect, 5, .fn) }             // globe/fn-key variants
        // Extra F-keys (F13-F20) and misc function keys sit at the right of the function row.
        for code: UInt16 in [105, 107, 113, 106, 64, 79, 80, 90] {
            if let r = byCode[111]?.rect { put(code, r, 0, .function) }
        }
        // Home/End/PageUp/PageDown/help (fn+arrows) at the arrow cluster.
        for code: UInt16 in [115, 119, 116, 121, 114] {
            if let r = byCode[126]?.rect { put(code, r, 5, .arrow) }
        }
        // ISO extra key and JIS yen sit by left shift / backslash.
        if let r = byCode[56]?.rect { put(10, CGRect(x: r.minX + 0.5, y: r.minY, width: 1, height: 1), 4, .generic) }
        if let r = byCode[42]?.rect { put(93, r, 2, .generic) }
        return t
    }()

    /// Normalised position and class for a virtual keycode (unknown keys → centre, generic).
    static func position(for keyCode: UInt16) -> (x: Float, y: Float, row: Int, kind: KeyKind) {
        let e = table[Int(keyCode & 0xFF)]
        return (e.x, e.y, Int(e.row), e.kind)
    }
}
