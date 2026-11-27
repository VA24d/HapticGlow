// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Pure wallpaper maths: fit modes, integer scaling, animation timing, pause gating, desktop-picture classification.
import Foundation
import CoreGraphics
import QuartzCore

enum WallpaperFit: String, Codable, CaseIterable, Sendable, Identifiable {
    case fill, fit, stretch, center, pixelArt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        case .pixelArt: return "Pixel art"
        }
    }
}

enum WallpaperLayout {
    /// Largest whole number of image pixels per screen pixel that still fits. Returns 0 when the image is
    /// larger than the screen in either direction, so callers can fall back to a plain fit.
    static func integerScale(content: CGSize, screenPixels: CGSize) -> Int {
        guard content.width > 0, content.height > 0 else { return 0 }
        let s = min(screenPixels.width / content.width, screenPixels.height / content.height)
        return s >= 1 ? Int(s.rounded(.down)) : 0
    }

    /// Frame of the content inside a view of `bounds` points. `content` is in pixels, `backing` is the
    /// screen's pixels-per-point. The result is snapped to whole screen pixels.
    static func rect(fit: WallpaperFit, content: CGSize, bounds: CGSize, backing: CGFloat) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let b = max(backing, 1)
        func centred(_ size: CGSize) -> CGRect {
            snap(CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                        width: size.width, height: size.height), backing: b)
        }
        switch fit {
        case .stretch: return CGRect(origin: .zero, size: bounds)
        case .fill:
            let s = max(bounds.width / content.width, bounds.height / content.height)
            return centred(CGSize(width: content.width * s, height: content.height * s))
        case .fit:
            let s = min(bounds.width / content.width, bounds.height / content.height)
            return centred(CGSize(width: content.width * s, height: content.height * s))
        case .center:
            return centred(CGSize(width: content.width / b, height: content.height / b))
        case .pixelArt:
            let px = CGSize(width: bounds.width * b, height: bounds.height * b)
            let n = integerScale(content: content, screenPixels: px)
            if n == 0 { return rect(fit: .fit, content: content, bounds: bounds, backing: b) }
            let k = CGFloat(n) / b
            return centred(CGSize(width: content.width * k, height: content.height * k))
        }
    }

    static func snap(_ r: CGRect, backing: CGFloat) -> CGRect {
        func s(_ v: CGFloat) -> CGFloat { (v * backing).rounded() / backing }
        let x0 = s(r.minX), y0 = s(r.minY), x1 = s(r.maxX), y1 = s(r.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Animation timing for decoded frame sequences.
enum AnimationTiming {
    /// Browsers treat GIF delays of 0 or 1 cs as 100 ms; so do we.
    static func clampedDelay(_ d: Double?) -> Double {
        guard let d, d.isFinite, d > 0.011 else { return 0.1 }
        return d
    }

    /// Frame showing at time `t` (seconds since start) when the sequence loops forever.
    static func frameIndex(at t: Double, delays: [Double]) -> Int {
        let total = delays.reduce(0, +)
        guard !delays.isEmpty, total > 0, t.isFinite else { return 0 }
        var rem = t.truncatingRemainder(dividingBy: total)
        if rem < 0 { rem += total }
        var acc = 0.0
        for (i, d) in delays.enumerated() {
            acc += d
            if rem < acc { return i }
        }
        return delays.count - 1
    }

    /// Seconds from `t` until the next frame starts (loop-aware); at least a millisecond.
    static func timeToNextFrame(at t: Double, delays: [Double]) -> Double {
        let total = delays.reduce(0, +)
        guard !delays.isEmpty, total > 0, t.isFinite else { return 0.1 }
        var rem = t.truncatingRemainder(dividingBy: total)
        if rem < 0 { rem += total }
        var acc = 0.0
        for d in delays { acc += d; if rem < acc { return max(acc - rem, 0.001) } }
        return max(total - rem, 0.001)
    }

    /// Panel refresh range to ask a display link for while an animation plays. The preferred rate is the content's
    /// fastest frame rate (so no frame is late), capped by the user's limit; ProMotion may then run the panel
    /// anywhere inside min...max instead of its full 120 Hz. A 12 fps GIF asks for 8 / 12 / 15.
    static func frameRateRange(delays: [Double], cap: Int) -> CAFrameRateRange {
        let shortest = delays.filter { $0 > 0 }.min() ?? 0.1
        let capF = Double(max(1, cap))
        let preferred = max(1, min(1 / shortest, capF).rounded())
        let upper = max(preferred, min((preferred * 1.25).rounded(.up), capF))
        let lower = max(1, (preferred * 2 / 3).rounded(.down))
        return CAFrameRateRange(minimum: Float(lower), maximum: Float(upper), preferred: Float(preferred))
    }

    /// Whether every decoded frame fits the memory budget, so the loop can be cached instead of re-decoded.
    static func canCache(frames: Int, width: Int, height: Int, budgetBytes: Int) -> Bool {
        guard frames > 0, width > 0, height > 0 else { return false }
        let (bytes, overflow) = frames.multipliedReportingOverflow(by: width * height * 4)
        return !overflow && bytes <= budgetBytes
    }

    /// Size to decode at: the native size, shrunk only when a side exceeds what the screen can show.
    static func decodeMaxPixel(contentMax: Int, screenMax: Int) -> Int { max(1, min(contentMax, max(screenMax, 1))) }
}

/// Why playback is held. Any reason pauses; the saver shows a still frame instead of freezing mid-motion.
enum PauseReason: String, Hashable, CaseIterable, Sendable {
    case covered, displaySleep, locked, sessionInactive, saver, user
    var text: String {
        switch self {
        case .covered: return "a window or full-screen app covers the desktop"
        case .displaySleep: return "the display is asleep"
        case .locked: return "the screen is locked"
        case .sessionInactive: return "another user session is active"
        case .saver: return "battery saver is on"
        case .user: return "paused by you"
        }
    }
}

struct PauseGate: Equatable, Sendable {
    private(set) var reasons: Set<PauseReason> = []
    var isPaused: Bool { !reasons.isEmpty }
    /// The saver is holding playback: show the still frame instead of a frozen mid-motion frame.
    var showsStill: Bool { reasons.contains(.saver) }
    mutating func set(_ r: PauseReason, _ on: Bool) { if on { reasons.insert(r) } else { reasons.remove(r) } }
    var summary: String? {
        let order: [PauseReason] = [.user, .saver, .locked, .displaySleep, .sessionInactive, .covered]
        return order.first(where: reasons.contains)?.text
    }
}

/// How a screen's current desktop picture can be put back.
enum DesktopPictureKind: Equatable, Sendable { case restorable, appleDynamic, missing }

enum DesktopPictureClassifier {
    /// Apple dynamic, aerial and Sonoma-style wallpapers are not a plain file the app can set again.
    static func classify(path: String?, fileExists: Bool) -> DesktopPictureKind {
        guard let path, !path.isEmpty else { return .missing }
        let p = path.lowercased()
        let dynamicMarkers = ["idleassetsd", "/assetsv2/", "mobileasset", ".madesktop", "/aerials", "com.apple.wallpaper"]
        if dynamicMarkers.contains(where: { p.contains($0) }) { return .appleDynamic }
        if p.hasSuffix(".heic") && p.hasPrefix("/system/library/desktop pictures") { return .appleDynamic }
        return fileExists ? .restorable : .missing
    }
}

enum WallpaperPlaylist {
    static func next(after current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let c = current, let i = ids.firstIndex(of: c) else { return ids[0] }
        return ids[(i + 1) % ids.count]
    }
}
