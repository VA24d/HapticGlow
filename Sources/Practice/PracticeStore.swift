// Practice persistence: results history, personal bests and per-key stats (UserDefaults, key practice.v1).
import Foundation
import Observation

struct KeyStat: Codable, Sendable, Equatable {
    var count = 0          // times this key was the expected key
    var misses = 0         // times it was expected and something else was typed
    var latSum = 0.0       // summed latency (ms) of correct hits
    var latSamples = 0
    var meanLatency: Double? { latSamples > 0 ? latSum / Double(latSamples) : nil }
    var missRate: Double { count > 0 ? Double(misses) / Double(count) : 0 }
}

struct PracticeResult: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var modeKey: String            // "words 25", "time 30", "quote", "code", "weak"
    var wpm: Double
    var raw: Double
    var accuracy: Double
    var consistency: Double
    var seconds: Double
    var errorsByKey: [String: Int] = [:]
    var wpmSamples: [Double] = []
    var rawSamples: [Double] = []
    var errorSamples: [Int] = []
    var isBest = false
}

struct PracticeData: Codable, Sendable {
    var history: [PracticeResult] = []
    var bests: [String: Double] = [:]
    var keys: [String: KeyStat] = [:]
}

@MainActor
@Observable
final class PracticeStore {
    static let defaultsKey = "practice.v1"
    static let maxHistory = 200
    private(set) var data = PracticeData()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.data(forKey: Self.defaultsKey),
           let d = try? JSONDecoder().decode(PracticeData.self, from: raw) { data = d }
    }

    /// Commit a finished test: history, personal best, and per-key stats from the keystroke log.
    @discardableResult
    func commit(result: PracticeResult, log: [Keystroke]) -> PracticeResult {
        var r = result
        for k in log {
            guard let e = k.expected else { continue }
            let key = String(e).lowercased()
            var s = data.keys[key] ?? KeyStat()
            s.count += 1
            if k.correct {
                if let l = k.latencyMs { s.latSum += l; s.latSamples += 1 }
            } else { s.misses += 1 }
            data.keys[key] = s
        }
        if r.wpm > (data.bests[r.modeKey] ?? 0), r.wpm > 0 { data.bests[r.modeKey] = r.wpm; r.isBest = true }
        data.history.insert(r, at: 0)
        if data.history.count > Self.maxHistory { data.history.removeLast(data.history.count - Self.maxHistory) }
        save()
        return r
    }

    func reset() { data = PracticeData(); save() }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) { defaults.set(raw, forKey: Self.defaultsKey) }
    }
}
