// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Typing test engine: pure value logic (no UI, no clock). Time is passed in as seconds so it is testable.
// Word model follows the Monkeytype convention: Space commits a word, extra characters are allowed
// (and shown), Backspace edits the current word, and an incorrect committed word can be re-entered.
import Foundation

struct Keystroke: Sendable {
    let t: Double              // seconds since the first key
    let expected: Character?   // nil for extra characters typed past the end of a word
    let typed: Character
    let correct: Bool
    let latencyMs: Double?     // gap since the previous keystroke (nil for the first key or after a pause)
}

struct TypingMetrics: Sendable {
    var seconds: Double = 0
    var wpm: Double = 0
    var raw: Double = 0
    var accuracy: Double = 100
    var consistency: Double = 100
    var correctChars = 0
    var incorrectChars = 0
    var extraChars = 0
    var missedChars = 0
    var keystrokes = 0
    var wrongKeystrokes = 0
    var wpmSamples: [Double] = []
    var rawSamples: [Double] = []
    var errorSamples: [Int] = []
    var errorsByKey: [String: Int] = [:]
}

struct TypingEngine: Sendable {
    static let maxExtra = 10
    /// Gaps longer than this are pauses, not key latency.
    static let latencyCap = 1500.0

    private(set) var words: [String]
    private(set) var typed: [String]
    private(set) var current = 0
    private(set) var log: [Keystroke] = []
    private(set) var startedAt: Double? = nil      // absolute time of the first key
    private(set) var lastT: Double? = nil
    private var corrections = 0
    private(set) var finished = false
    /// Words mode ends when the last word is complete; timed mode never ends by itself.
    var endsOnCompletion = true

    init(words: [String], endsOnCompletion: Bool = true) {
        self.words = words.filter { !$0.isEmpty }
        self.typed = Array(repeating: "", count: self.words.count)
        self.endsOnCompletion = endsOnCompletion
    }

    var started: Bool { startedAt != nil }
    var currentTyped: String { typed.indices.contains(current) ? typed[current] : "" }

    mutating func appendWords(_ more: [String]) {
        let w = more.filter { !$0.isEmpty }
        words += w; typed += Array(repeating: "", count: w.count)
    }

    // MARK: input

    /// Type one character at absolute time `now` (seconds). Returns false when ignored.
    @discardableResult
    mutating func type(_ ch: Character, now: Double) -> Bool {
        guard !finished, current < words.count else { return false }
        if ch == " " {
            guard !typed[current].isEmpty else { return false }
            return commitWord(now: now)
        }
        guard typed[current].count < words[current].count + Self.maxExtra else { return false }
        let t = stamp(now)
        let pos = typed[current].count
        let w = Array(words[current])
        let expected: Character? = pos < w.count ? w[pos] : nil
        let ok = expected == ch
        typed[current].append(ch)
        record(Keystroke(t: t, expected: expected, typed: ch, correct: ok, latencyMs: latency(t)))
        if endsOnCompletion, current == words.count - 1, typed[current] == words[current] {
            current += 1; finished = true      // last word typed exactly: no trailing space needed
        }
        return true
    }

    private mutating func commitWord(now: Double) -> Bool {
        let t = stamp(now)
        // Space is the expected key at a word end. It is only an error when pressed early (skipped
        // letters); a wrong word is already penalised by its wrong letters.
        let ok = typed[current].count >= words[current].count
        record(Keystroke(t: t, expected: " ", typed: " ", correct: ok, latencyMs: latency(t)))
        current += 1
        if current >= words.count && endsOnCompletion { finished = true }
        return true
    }

    /// Backspace. `word` deletes the whole current word (Option+Backspace).
    mutating func backspace(word: Bool = false, now: Double) {
        guard !finished else { return }
        if current < words.count, !typed[current].isEmpty {
            if word { typed[current] = "" } else { typed[current].removeLast() }
            corrections += 1
        } else if current > 0, current <= words.count, typed[current - 1] != words[current - 1] {
            current -= 1                                  // step back into a wrong word to fix it
            if word { typed[current] = "" } else if !typed[current].isEmpty { typed[current].removeLast() }
            corrections += 1
        }
        if started { lastT = stamp(now) }
    }

    mutating func finish(now: Double) {
        if let s = startedAt, lastT != nil { lastT = max(lastT ?? 0, now - s) }
        finished = true
    }

    // MARK: bookkeeping

    private mutating func stamp(_ now: Double) -> Double {
        if startedAt == nil { startedAt = now }
        return now - startedAt!
    }
    private func latency(_ t: Double) -> Double? {
        guard let l = lastT else { return nil }
        let ms = (t - l) * 1000
        return ms > 0 && ms <= Self.latencyCap ? ms : nil
    }
    private mutating func record(_ k: Keystroke) { log.append(k); lastT = k.t }

    // MARK: metrics

    /// Characters that count toward WPM: fully correct words (+ their space) and the matching prefix of the current word.
    var correctChars: Int {
        var n = 0
        for i in 0..<min(current, words.count) where typed[i] == words[i] { n += words[i].count + 1 }
        if current < words.count {
            let a = Array(typed[current]), b = Array(words[current])
            for j in 0..<min(a.count, b.count) where a[j] == b[j] { n += 1 }
        }
        // The final word needs no space.
        if finished, current >= words.count, let last = words.indices.last, typed[last] == words[last] { n -= 1 }
        return max(0, n)
    }

    /// Live numbers at `elapsed` seconds into the test.
    func live(elapsed: Double) -> (wpm: Double, raw: Double, accuracy: Double) {
        let m = max(elapsed, 0.5) / 60
        let raw = Double(log.count) / 5 / m
        let wrong = log.filter { !$0.correct }.count
        let acc = log.isEmpty ? 100 : 100 * Double(log.count - wrong) / Double(log.count)
        return (Double(correctChars) / 5 / m, raw, acc)
    }

    /// Final metrics. `duration` overrides the elapsed time (timed mode uses the full limit).
    func metrics(duration: Double? = nil) -> TypingMetrics {
        var m = TypingMetrics()
        let last = log.last?.t ?? 0
        let secs = max(duration ?? max(last, lastT ?? 0), 0.001)
        m.seconds = secs
        m.keystrokes = log.count
        m.wrongKeystrokes = log.filter { !$0.correct }.count
        m.extraChars = log.filter { $0.expected == nil }.count
        m.accuracy = log.isEmpty ? 100 : 100 * Double(log.count - m.wrongKeystrokes) / Double(log.count)
        // Character classes from the final text state.
        for i in 0..<words.count {
            let a = Array(typed[i]), b = Array(words[i])
            if i > current || (i == current && a.isEmpty) { continue }
            let committed = i < current
            for j in 0..<min(a.count, b.count) { if a[j] == b[j] { m.correctChars += 1 } else { m.incorrectChars += 1 } }
            if committed && a.count < b.count { m.missedChars += b.count - a.count }
        }
        m.correctChars = correctChars
        m.wpm = Double(m.correctChars) / 5 / (secs / 60)
        m.raw = Double(m.keystrokes) / 5 / (secs / 60)
        for k in log where !k.correct { m.errorsByKey[String(k.expected ?? k.typed), default: 0] += 1 }

        // Per-second samples. WPM replays committed words; raw/errors count keystrokes in that second.
        let n = max(1, Int(secs.rounded(.up)))
        var rawPer = [Double](repeating: 0, count: n), errPer = [Int](repeating: 0, count: n)
        for k in log {
            let s = min(n - 1, Int(k.t))
            rawPer[s] += 1; if !k.correct { errPer[s] += 1 }
        }
        var cum = 0.0, wpmS: [Double] = [], rawS: [Double] = []
        for s in 0..<n {
            cum += rawPer[s]
            let el = min(Double(s + 1), secs)
            // Correct-so-far proxy: cumulative keystrokes minus cumulative wrong, scaled.
            let wrongSoFar = Double(errPer[0...s].reduce(0, +))
            wpmS.append(max(0, (cum - wrongSoFar) / 5 / (el / 60)))
            rawS.append(rawPer[s] * 12)         // per-second keystrokes -> wpm
        }
        m.wpmSamples = wpmS; m.rawSamples = rawS; m.errorSamples = errPer
        m.consistency = Self.consistency(of: rawS)
        return m
    }

    /// Monkeytype-style: 100 at constant speed, falling with the coefficient of variation.
    static func consistency(of xs: [Double]) -> Double {
        let v = xs.dropLast(xs.count > 3 ? 1 : 0).filter { $0 >= 0 }   // drop the partial last second
        guard v.count >= 2 else { return 100 }
        let mean = v.reduce(0, +) / Double(v.count)
        guard mean > 0 else { return 0 }
        let sd = (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot()
        let cv = sd / mean
        return max(0, min(100, 100 * (1 - tanh(cv + pow(cv, 3) / 3 + pow(cv, 5) / 5))))
    }
}

// MARK: - Layout (monospaced word wrap, shared by the view and tests)

struct WordSlot: Sendable { let line: Int; let col: Int; let length: Int }

enum TextWrap {
    /// Greedy word wrap in character columns. A word's length grows with extra typed characters.
    static func slots(words: [String], typed: [String], current: Int, cols: Int) -> [WordSlot] {
        let cols = max(8, cols)
        var out: [WordSlot] = []
        var line = 0, col = 0
        for (i, w) in words.enumerated() {
            let extra = i < typed.count ? max(0, typed[i].count - w.count) : 0
            let len = w.count + extra
            if col > 0 && col + len > cols { line += 1; col = 0 }
            out.append(WordSlot(line: line, col: col, length: len))
            col += len + 1
        }
        return out
    }
}
