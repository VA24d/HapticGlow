// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Practice text sources: common words, public-domain quotes, short code lines, and the adaptive generator.
import Foundation
import NaturalLanguage

/// Small seedable RNG so generators are reproducible in tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum PracticeContent {
    static let words: [String] = """
    the be to of and a in that have it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was were been has had did said each many may find long down made world still own here thing great old right big high small large next early young few public bad same able
    house water school small night story point city play sound light keep never home life hand part place case week group number system line side family mind open seem together real change point follow stop write read learn move turn start show hear run begin walk talk end food room music book close both between under last might while ask need feel leave call try head word eye face door car friend city tree river stone green blue red field bright dark quick brown fox jump lazy dog quiet loud simple strong gentle clear sharp smooth rough heavy
    morning evening window garden mountain machine pattern letter paper pocket silver golden shadow thunder whisper journey bridge candle forest island market ocean planet rocket season ticket valley winter yellow zipper quartz wizard exact fixed jazz quiz maybe oxygen vivid zebra
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    struct Quote: Sendable { let text: String; let source: String }
    static let quotes: [Quote] = [
        .init(text: "The only thing we have to fear is fear itself.", source: "Franklin D. Roosevelt"),
        .init(text: "It was the best of times, it was the worst of times.", source: "Charles Dickens"),
        .init(text: "All that we see or seem is but a dream within a dream.", source: "Edgar Allan Poe"),
        .init(text: "Whenever you find yourself on the side of the majority, it is time to pause and reflect.", source: "Mark Twain"),
        .init(text: "I have not failed. I have just found ten thousand ways that will not work.", source: "Thomas Edison"),
        .init(text: "The unexamined life is not worth living.", source: "Socrates"),
        .init(text: "To be, or not to be, that is the question.", source: "William Shakespeare"),
        .init(text: "Ask not what your country can do for you, ask what you can do for your country.", source: "John F. Kennedy"),
        .init(text: "The journey of a thousand miles begins with a single step.", source: "Lao Tzu"),
        .init(text: "We are what we repeatedly do. Excellence, then, is not an act but a habit.", source: "Will Durant"),
        .init(text: "In the middle of difficulty lies opportunity.", source: "Albert Einstein"),
        .init(text: "Nothing is particularly hard if you divide it into small jobs.", source: "Henry Ford"),
        .init(text: "A person who never made a mistake never tried anything new.", source: "Albert Einstein"),
        .init(text: "Well done is better than well said.", source: "Benjamin Franklin"),
    ]

    static let code: [String] = [
        "let total = items.reduce(0) { $0 + $1.price }",
        "func greet(_ name: String) -> String { \"Hello, \\(name)\" }",
        "guard let url = URL(string: text) else { return }",
        "for (index, item) in list.enumerated() { print(index, item) }",
        "struct Point: Hashable { var x: Double; var y: Double }",
        "let sorted = names.sorted { $0.count < $1.count }",
        "if case .success(let value) = result { use(value) }",
        "var cache: [String: Int] = [:]",
        "Task { @MainActor in model.refresh() }",
        "def mean(xs): return sum(xs) / len(xs)",
        "squares = [n * n for n in range(10) if n % 2 == 0]",
        "with open(path) as f: lines = f.read().splitlines()",
        "for key, value in sorted(counts.items()): print(key, value)",
        "class Stack: def __init__(self): self.items = []",
        "result = {k: v for k, v in pairs if v is not None}",
        "const ok = items.filter((x) => x.ready).map((x) => x.id);",
    ]

    static func randomWords(_ n: Int, using rng: inout some RandomNumberGenerator) -> [String] {
        var out: [String] = []
        while out.count < n {
            let w = words.randomElement(using: &rng)!
            if w != out.last { out.append(w) }
        }
        return out
    }

    static func quote(using rng: inout some RandomNumberGenerator) -> Quote { quotes.randomElement(using: &rng)! }

    static func codeLines(_ n: Int, using rng: inout some RandomNumberGenerator) -> [String] {
        Array(code.shuffled(using: &rng).prefix(n)).flatMap { $0.split(separator: " ").map(String.init) }
    }
}

// MARK: - Adaptive drills

enum AdaptiveGenerator {
    static let minSamples = 4

    /// Weights per character (letters only). Higher = needs more practice.
    static func weights(stats: [String: KeyStat]) -> [Character: Double] {
        let lat = stats.values.filter { $0.latSamples > 0 }
        let meanLat = lat.isEmpty ? 0 : lat.reduce(0) { $0 + $1.latSum } / Double(lat.reduce(0) { $0 + $1.latSamples })
        var w: [Character: Double] = [:]
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            guard let s = stats[String(ch)], s.count >= minSamples else { w[ch] = 0.35; continue }   // unknown: mild interest
            let miss = (Double(s.misses) + 0.3) / (Double(s.count) + 3)
            var slow = 0.0
            if meanLat > 0, s.latSamples > 0 { slow = max(0, (s.latSum / Double(s.latSamples)) / meanLat - 1) }
            w[ch] = 0.15 + 9 * miss + 1.6 * slow
        }
        return w
    }

    /// True once at least one letter has real data.
    static func hasData(_ stats: [String: KeyStat]) -> Bool {
        stats.contains { $0.key.count == 1 && $0.value.count >= minSamples && $0.key.first!.isLetter }
    }

    /// The `n` letters with the highest weight among those with enough samples.
    static func weakest(stats: [String: KeyStat], n: Int = 5) -> [Character] {
        let w = weights(stats: stats)
        return w.filter { (stats[String($0.key)]?.count ?? 0) >= minSamples }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key)
    }

    /// Real words that emphasise weak letters: macOS dictionary words (see `Lexicon`) ranked by how much
    /// of each word is weak letters, sampled from the best few hundred so drills stay varied.
    static func words(count: Int, stats: [String: KeyStat], using rng: inout some RandomNumberGenerator) -> [String] {
        let w = weights(stats: stats)
        let focus = Set(weakest(stats: stats, n: 3))
        func score(_ word: String) -> Double {
            var sum = 0.0, hits = 0
            for ch in word { sum += w[ch] ?? 0.2; if focus.contains(ch) { hits += 1 } }
            // density of weak letters, a bonus for each focus letter, and a mild preference for short words
            return sum / Double(word.count).squareRoot() + 0.8 * Double(min(hits, 3)) - 0.06 * Double(max(0, word.count - 6))
        }
        var pool = Lexicon.words
        if !focus.isEmpty { pool = pool.filter { $0.contains(where: focus.contains) } }
        if pool.count < 50 { pool = PracticeContent.words }
        let ranked = pool.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.prefix(600)
        let floor = ranked.last?.1 ?? 0
        let weighted = ranked.map { ($0.0, max(0.05, $0.1 - floor + 0.2)) }
        let total = weighted.reduce(0) { $0 + $1.1 }
        func pick() -> String {
            var r = Double.random(in: 0..<total, using: &rng)
            for (word, s) in weighted { r -= s; if r <= 0 { return word } }
            return weighted.last!.0
        }
        var out: [String] = []
        var guardN = 0
        while out.count < count && guardN < count * 20 {
            guardN += 1
            let word = pick()
            if !out.suffix(8).contains(word) { out.append(word) }
        }
        return out
    }
}

/// Real English words from the macOS dictionary (/usr/share/dict/words), kept only when Apple's
/// built-in English word model (NaturalLanguage) also knows them. That drops most archaic and
/// technical entries: about 23,000 words of 3-9 lowercase letters remain. Loads in ~0.1 s, once.
enum Lexicon {
    static let words: [String] = load()

    /// Call early (off the main thread) so the first drill does not wait for the load.
    static func preload() { DispatchQueue.global(qos: .utility).async { _ = words.count } }

    private static let blocked: Set<String> = [
        "fag", "faggot", "nigger", "nigga", "retard", "retarded", "slut", "whore", "bitch", "bastard",
        "cunt", "dick", "fuck", "fucker", "shit", "cock", "pussy", "twat", "wank", "wanker", "rape",
        "rapist", "spic", "chink", "kike", "dyke", "tranny", "coon", "gook",
    ]

    private static func load() -> [String] {
        guard let raw = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return PracticeContent.words }
        let model = NLEmbedding.wordEmbedding(for: .english)
        var out: [String] = []
        out.reserveCapacity(24_000)
        for sub in raw.split(separator: "\n") {
            guard sub.count >= 3, sub.count <= 9, sub.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { continue }
            let w = String(sub)
            if blocked.contains(w) { continue }
            if let model, !model.contains(w) { continue }
            out.append(w)
        }
        return out.count >= 500 ? out : PracticeContent.words
    }
}
