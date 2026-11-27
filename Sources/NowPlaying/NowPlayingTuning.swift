// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Per-song tuning: the knobs a song can override, the genre preset table (the only place genres are
// mapped to settings) and the capped, least-recently-used memory of saved songs. Pure data and logic.
import Foundation

/// The existing haptic and glow settings a song or genre may override. Audio sync is deliberately absent:
/// it belongs to the output device, not the song.
enum TuneKnob: String, CaseIterable, Sendable {
    case strength, texture, detail, rumble, punch, pitch, cutoffHz, feel, hapticMode
    case glowMode, ceiling, floor, speed, sensitivity

    var isGlow: Bool {
        switch self {
        case .glowMode, .ceiling, .floor, .speed, .sensitivity: return true
        default: return false
        }
    }

    func read(_ h: HapticConfig, _ g: GlowConfig) -> TuneValue {
        switch self {
        case .strength: return .number(h.strength)
        case .texture: return .number(h.texture)
        case .detail: return .number(h.detail)
        case .rumble: return .number(h.rumble)
        case .punch: return .number(h.punch)
        case .pitch: return .number(h.pitch)
        case .cutoffHz: return .number(h.cutoffHz)
        case .feel: return .word(h.feel.rawValue)
        case .hapticMode: return .word(h.mode.rawValue)
        case .glowMode: return .word(g.mode.rawValue)
        case .ceiling: return .number(g.ceiling)
        case .floor: return .number(g.floor)
        case .speed: return .number(g.speed)
        case .sensitivity: return .number(g.sensitivity)
        }
    }

    /// Writes a value, clamped to the range the setting's own decoder accepts. Bad values are ignored.
    func write(_ v: TuneValue, _ h: inout HapticConfig, _ g: inout GlowConfig) {
        func n(_ lo: Float, _ hi: Float) -> Float? {
            guard case .number(let x) = v, x.isFinite else { return nil }
            return min(hi, max(lo, x))
        }
        switch self {
        case .strength: if let x = n(0, 1) { h.strength = x }
        case .texture: if let x = n(0, 1) { h.texture = x }
        case .detail: if let x = n(0, 1) { h.detail = x }
        case .rumble: if let x = n(0, 1) { h.rumble = x }
        case .punch: if let x = n(0, 1) { h.punch = x }
        case .pitch: if let x = n(0, 1) { h.pitch = x }
        case .cutoffHz: if let x = n(40, 250) { h.cutoffHz = x }
        case .feel: if case .word(let s) = v, let f = HapticFeel(rawValue: s) { h.feel = f }
        case .hapticMode: if case .word(let s) = v, let m = HapticMode(rawValue: s) { h.mode = m }
        case .glowMode: if case .word(let s) = v, let m = GlowMode(rawValue: s) { g.mode = m }
        case .ceiling: if let x = n(0.05, 1) { g.ceiling = x; if g.floor > x { g.floor = x } }
        case .floor: if let x = n(0, 1) { g.floor = min(x, g.ceiling) }
        case .speed: if let x = n(0.25, 4) { g.speed = x }
        case .sensitivity: if let x = n(0.25, 3) { g.sensitivity = x }
        }
    }
}

enum TuneValue: Codable, Equatable, Sendable {
    case number(Float)
    case word(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let f = try? c.decode(Float.self) { self = .number(f) }
        else if let s = try? c.decode(String.self) { self = .word(s) }
        else { self = .word("") }   // unreadable: kept harmless, ignored on apply
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let f): try c.encode(f)
        case .word(let s): try c.encode(s)
        }
    }
}

/// A set of knob values. Only the knobs present are applied.
struct SongTuning: Codable, Equatable, Sendable {
    var values: [String: TuneValue] = [:]

    init(_ pairs: [TuneKnob: TuneValue] = [:]) {
        for (k, v) in pairs { values[k.rawValue] = v }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        values = (try? c.decode([String: TuneValue].self)) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }

    var isEmpty: Bool { knobs.isEmpty }
    /// Known knobs only; unknown keys from a newer version are carried but never applied.
    var knobs: [TuneKnob] { TuneKnob.allCases.filter { values[$0.rawValue] != nil } }
    subscript(k: TuneKnob) -> TuneValue? {
        get { values[k.rawValue] }
        set { values[k.rawValue] = newValue }
    }
    /// `other` wins where both set a knob.
    func merged(with other: SongTuning) -> SongTuning {
        var m = self
        for (k, v) in other.values { m.values[k] = v }
        return m
    }
}

// MARK: - Genre presets (the single mapping table)

enum GenrePresets {
    struct Preset {
        let name: String        // shown to the user
        let terms: [String]     // matched against the words of the genre string
        let tuning: SongTuning
        var speech = false      // tells Auto the audio is spoken word, so it picks the Movie feel
    }

    /// First match wins, so the gentle and spoken groups come before the heavy ones ("Ambient Electronic" is gentle).
    static let all: [Preset] = [
        Preset(name: "Spoken word", terms: ["podcast", "audiobook", "spoken"], tuning: SongTuning(), speech: true),
        Preset(name: "Smooth swells",
               terms: ["soundtrack", "score", "classical", "ambient", "orchestral", "opera", "chamber", "piano", "meditation"],
               tuning: SongTuning([.detail: .number(0.2), .punch: .number(0.25), .texture: .number(0.75),
                                   .feel: .word(HapticFeel.deep.rawValue), .glowMode: .word(GlowMode.bassFollow.rawValue)])),
        Preset(name: "Snare emphasis",
               terms: ["rock", "metal", "punk", "grunge", "hardcore"],
               tuning: SongTuning([.detail: .number(0.8), .punch: .number(0.6), .texture: .number(0.3),
                                   .feel: .word(HapticFeel.punchy.rawValue)])),
        Preset(name: "Bass-forward",
               terms: ["hip", "hop", "rap", "trap", "drill", "grime", "electronic", "dance", "house", "techno", "trance",
                       "edm", "dubstep", "drum", "bass", "reggaeton"],
               tuning: SongTuning([.detail: .number(0.25), .punch: .number(0.7), .texture: .number(0.65),
                                   .cutoffHz: .number(110), .feel: .word(HapticFeel.deep.rawValue)])),
    ]

    static func words(_ genre: String) -> [String] {
        genre.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Unknown or empty genres return nil, which leaves the settings unchanged.
    static func match(_ genre: String) -> Preset? {
        let ws = words(genre)
        guard !ws.isEmpty else { return nil }
        return all.first { p in
            p.terms.contains { t in ws.contains { $0 == t || (t.count >= 4 && $0.hasPrefix(t)) } }
        }
    }
}

// MARK: - Memory

struct SongMemoryEntry: Codable, Equatable, Sendable {
    var key: String
    var title: String
    var artist: String
    var tuning: SongTuning
    var used: Double
}

/// Saved songs, newest use last. Capped; the least recently used entry goes first.
struct SongMemory: Sendable {
    static let cap = 500
    private(set) var entries: [SongMemoryEntry] = []

    init(entries: [SongMemoryEntry] = []) {
        self.entries = Array(entries.suffix(Self.cap))
    }

    func tuning(for key: String) -> SongTuning? { entries.first { $0.key == key }?.tuning }

    mutating func set(key: String, title: String, artist: String, tuning: SongTuning, now: Double) {
        entries.removeAll { $0.key == key }
        entries.append(SongMemoryEntry(key: key, title: title, artist: artist, tuning: tuning, used: now))
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
    }

    /// Marks a song as used just now. Returns false when it is not saved.
    @discardableResult
    mutating func touch(_ key: String, now: Double) -> Bool {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return false }
        var e = entries.remove(at: i)
        e.used = now
        entries.append(e)
        return true
    }

    mutating func remove(_ key: String) { entries.removeAll { $0.key == key } }

    /// Tolerant: unreadable entries are skipped, the rest are kept.
    static func decode(_ data: Data?) -> SongMemory {
        struct Lossy: Decodable {
            let value: SongMemoryEntry?
            init(from decoder: Decoder) throws { value = try? SongMemoryEntry(from: decoder) }
        }
        guard let data, let list = try? JSONDecoder().decode([Lossy].self, from: data) else { return SongMemory() }
        return SongMemory(entries: list.compactMap(\.value).filter { !$0.key.isEmpty })
    }
    func encoded() -> Data? { try? JSONEncoder().encode(entries) }
}
