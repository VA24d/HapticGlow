// Practice session controller: owns the current test, turns KeyCatcher events into engine input,
// runs the clock, commits results. UI-independent apart from KeyCatcherEvent.
import Foundation
import AppKit
import Observation

enum PracticeMode: String, CaseIterable, Identifiable, Sendable {
    case words, timed, quotes, code, weak
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: return "Words"
        case .timed: return "Timed"
        case .quotes: return "Quotes"
        case .code: return "Code"
        case .weak: return "Weak keys"
        }
    }
}

@MainActor
@Observable
final class PracticeSession {
    enum Phase { case ready, running, done }

    static let wordOptions = [25, 50, 100]
    static let timeOptions = [15, 30, 60]

    let store: PracticeStore
    var mode: PracticeMode = .words { didSet { if mode != oldValue { savePrefs(); newTest() } } }
    var wordCount = 25 { didSet { if wordCount != oldValue { savePrefs(); newTest() } } }
    var timeLimit = 30 { didSet { if timeLimit != oldValue { savePrefs(); newTest() } } }

    private(set) var engine = TypingEngine(words: ["start", "typing"])
    private(set) var phase: Phase = .ready
    private(set) var elapsed = 0.0
    private(set) var liveWPM = 0.0
    private(set) var liveRaw = 0.0
    private(set) var liveAccuracy = 100.0
    private(set) var metrics: TypingMetrics?
    private(set) var result: PracticeResult?
    private(set) var quoteSource: String?
    private(set) var needsDataNote = false
    private(set) var tabArmed = false

    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startUptime = 0.0
    @ObservationIgnored private var prefs: UserDefaults

    init(store: PracticeStore? = nil, defaults: UserDefaults = .standard) {
        Lexicon.preload()
        prefs = defaults
        self.store = store ?? PracticeStore(defaults: defaults)
        if let m = defaults.string(forKey: "practice.mode"), let pm = PracticeMode(rawValue: m) { mode = pm }
        let w = defaults.integer(forKey: "practice.words"); if Self.wordOptions.contains(w) { wordCount = w }
        let t = defaults.integer(forKey: "practice.time"); if Self.timeOptions.contains(t) { timeLimit = t }
        newTest()
    }
    deinit { MainActor.assumeIsolated { timer?.invalidate() } }

    private func savePrefs() {
        prefs.set(mode.rawValue, forKey: "practice.mode")
        prefs.set(wordCount, forKey: "practice.words")
        prefs.set(timeLimit, forKey: "practice.time")
    }

    var stats: [String: KeyStat] { store.data.keys }
    var weakLetters: [Character] { AdaptiveGenerator.weakest(stats: stats, n: 5) }

    /// Remaining seconds (timed) or words left (others), for the counter.
    var counterText: String {
        if mode == .timed { return String(max(0, Int((Double(timeLimit) - elapsed).rounded(.up)))) }
        return "\(min(engine.current, engine.words.count))/\(engine.words.count)"
    }

    // MARK: tests

    func newTest() {
        stopTimer()
        phase = .ready; elapsed = 0; liveWPM = 0; liveRaw = 0; liveAccuracy = 100
        metrics = nil; result = nil; quoteSource = nil; needsDataNote = false; tabArmed = false
        switch mode {
        case .words: engine = TypingEngine(words: PracticeContent.randomWords(wordCount, using: &rng))
        case .timed: engine = TypingEngine(words: PracticeContent.randomWords(80, using: &rng), endsOnCompletion: false)
        case .quotes:
            let q = PracticeContent.quote(using: &rng)
            quoteSource = q.source
            engine = TypingEngine(words: q.text.split(separator: " ").map(String.init))
        case .code: engine = TypingEngine(words: PracticeContent.codeLines(3, using: &rng))
        case .weak:
            needsDataNote = !AdaptiveGenerator.hasData(stats)
            engine = TypingEngine(words: AdaptiveGenerator.words(count: wordCount, stats: stats, using: &rng))
        }
    }

    /// Same text again.
    func repeatTest() {
        stopTimer()
        engine = TypingEngine(words: engine.words, endsOnCompletion: engine.endsOnCompletion)
        phase = .ready; elapsed = 0; liveWPM = 0; liveRaw = 0; liveAccuracy = 100
        metrics = nil; result = nil; tabArmed = false
    }

    // MARK: input

    func handle(_ e: KeyCatcherEvent) {
        let m = e.modifiers
        if m.contains(.command) { return }
        switch e.keyCode {
        case 53: newTest(); return                                   // Esc
        case 48: tabArmed = true; return                             // Tab (then Enter)
        case 36, 76: if tabArmed { newTest() } else { tabArmed = false }; return
        default: break
        }
        tabArmed = false
        guard phase != .done else { return }
        if e.keyCode == 51 {                                         // Backspace
            guard phase == .running else { return }
            engine.backspace(word: m.contains(.option), now: now)
            refreshLive(); return
        }
        if m.contains(.control) || e.isRepeat { return }
        for u in e.characters.unicodeScalars {
            guard u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value) else { continue }
            feed(Character(u))
            if phase == .done { break }
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func feed(_ c: Character, at time: Double? = nil) {
        if phase == .ready {
            guard c != " " else { return }
            phase = .running; startUptime = time ?? now
            if time == nil { startTimer() }
        }
        engine.type(c, now: time ?? now)
        if mode == .timed, engine.words.count - engine.current < 40 {
            engine.appendWords(mode == .timed ? PracticeContent.randomWords(50, using: &rng) : [])
        }
        refreshLive(at: time)
        if engine.finished { finish(at: time) }
    }

    private func refreshLive(at time: Double? = nil) {
        guard phase == .running else { return }
        elapsed = (time ?? now) - startUptime
        let l = engine.live(elapsed: elapsed)
        liveWPM = l.wpm; liveRaw = l.raw; liveAccuracy = l.accuracy
    }

    private func tick() {
        guard phase == .running else { return }
        refreshLive()
        if mode == .timed, elapsed >= Double(timeLimit) { finish() }
    }

    func finish(at time: Double? = nil) {
        guard phase == .running else { return }
        stopTimer()
        let t = time ?? now
        engine.finish(now: t)
        let dur: Double? = mode == .timed ? Double(timeLimit) : nil
        let m = engine.metrics(duration: dur)
        phase = .done
        guard m.keystrokes > 0 else { return }
        elapsed = m.seconds
        liveWPM = m.wpm; liveRaw = m.raw; liveAccuracy = m.accuracy
        metrics = m
        let key: String
        switch mode {
        case .words: key = "words \(wordCount)"
        case .timed: key = "time \(timeLimit)"
        case .quotes: key = "quote"
        case .code: key = "code"
        case .weak: key = "weak \(wordCount)"
        }
        let r = PracticeResult(modeKey: key, wpm: m.wpm, raw: m.raw, accuracy: m.accuracy, consistency: m.consistency,
                               seconds: m.seconds, errorsByKey: m.errorsByKey,
                               wpmSamples: m.wpmSamples.map { ($0 * 10).rounded() / 10 },
                               rawSamples: m.rawSamples, errorSamples: m.errorSamples)
        result = store.commit(result: r, log: engine.log)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: dev demo (HAPTICGLOW_PRACTICE_DEMO=typing|results), isolated from user data

    static func demo(_ kind: String) -> PracticeSession {
        let ud = UserDefaults(suiteName: "practice.demo")!
        ud.removePersistentDomain(forName: "practice.demo")
        let s = PracticeSession(defaults: ud)
        var g = SplitMix64(seed: 42)
        // Seed per-key stats: a few slow / error-prone keys.
        let slow = Set("qzxjpb"), sloppy = Set("qpyz")
        func run(words: Int) {
            s.mode = .words; s.wordCount = 25
            s.engine = TypingEngine(words: PracticeContent.randomWords(words, using: &g))
            s.phase = .ready
            var t = 100.0
            let target = s.engine.words
            for (wi, w) in target.enumerated() {
                for c in w {
                    t += Double.random(in: 0.06...0.16, using: &g) * (slow.contains(c) ? 2.4 : 1)
                    if sloppy.contains(c), Double.random(in: 0..<1, using: &g) < 0.3 {
                        s.feed("e", at: t); t += 0.15; s.engine.backspace(now: t);
                    }
                    if Double.random(in: 0..<1, using: &g) < 0.015 { s.feed("x", at: t); t += 0.12; s.engine.backspace(now: t) }
                    s.feed(c, at: t)
                    if kind == "typing", s.engine.current >= 3, s.engine.currentTyped.count >= 2 { return }
                }
                if wi < target.count - 1 { t += 0.09; s.feed(" ", at: t) }
            }
        }
        if kind == "results" {
            for _ in 0..<6 { run(words: 25); s.newTest() }
            run(words: 50)
        } else { run(words: 25) }
        return s
    }
}
