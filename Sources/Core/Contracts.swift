// HapticGlow — shared contract between engines and UI.
//
// FROZEN API: engines and UI are written against these exact names. Implementations may add
// private helpers and extra (defaulted) fields, but must not rename or remove anything here.
//
// Threading model
// - Audio tap IO thread  -> AudioAnalyzer.process(...) -> FeatureBus.publish(...)
//   FeatureBus listeners run synchronously on that thread: they must not block, allocate or lock
//   for long (copy the struct, signal a semaphore, return).
// - Key event-tap thread -> KeyBus.publish(...) -> listeners run synchronously on that thread.
// - GlowEngine / HapticEngine own their own high-priority threads.
// - UI (main thread) reads `latest()` snapshots and engine stats at display rate; never blocks engines.

import Foundation
import QuartzCore
import os

// MARK: - Time

/// Monotonic host time in seconds (same clock as CACurrentMediaTime / mach_absolute_time).
@inline(__always) func hostNow() -> Double { CACurrentMediaTime() }

// MARK: - Small lock helper (os_unfair_lock wrapper, safe to use from realtime-ish threads briefly)

final class UnfairLock: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<os_unfair_lock>
    init() { ptr = .allocate(capacity: 1); ptr.initialize(to: os_unfair_lock()) }
    deinit { ptr.deinitialize(count: 1); ptr.deallocate() }
    @inline(__always) func lock() { os_unfair_lock_lock(ptr) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(ptr) }
    @inline(__always) func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

/// A lock-protected value box for cross-thread config/stat handoff.
final class Locked<Value>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: Value
    init(_ v: Value) { value = v }
    func get() -> Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

// MARK: - Audio features

/// One analysis frame. Produced by AudioAnalyzer every hop (~5 ms). All levels are 0...1,
/// normalised with a slow AGC so quiet and loud masters behave alike.
struct AudioFeatures: Sendable {
    var time: Double = 0            // hostNow() when produced
    var level: Float = 0            // full-band loudness envelope
    var sub: Float = 0              // 20–60 Hz
    var bass: Float = 0             // 60–160 Hz
    var lowMid: Float = 0           // 160–500 Hz
    var mid: Float = 0              // 500–2000 Hz
    var high: Float = 0             // 2–16 kHz
    var bands = SIMD32<Float>()     // 32 log-spaced bands 30 Hz–16 kHz for the UI spectrum
    var belowCutoff: Float = 0      // envelope of energy below FeatureBus.cutoffHz (haptic bass)
    var bassPitchHz: Float = 0      // dominant pitch below cutoff, 0 if none / unvoiced
    var peaks = SIMD4<Float>()      // (hz1, amp1, hz2, amp2): two strongest peaks 150–4000 Hz, ≥200 Hz apart
    var onset: Bool = false         // low-band (kick/808) onset in this frame
    var onsetStrength: Float = 0    // 0...1 strength of that onset
    var onsetCount: UInt64 = 0      // total onsets so far (monotonic)
    var lastOnsetTime: Double = 0   // hostNow() of most recent onset (sample-accurate estimate)
    var bpm: Float = 0              // 0 if unknown
    var beatPhase: Float = 0        // 0..<1, 0 = predicted beat
    var silent: Bool = true         // true when no meaningful audio (or no tap callbacks)
    // Multi-band transients (Apple Music Haptics-style "taps"): strength 0...1 in the frame they fire, else 0.
    var snareOnset: Float = 0       // mid-band (150 Hz–2 kHz noisy) transient: snare / clap
    var hatOnset: Float = 0         // high-band (5–16 kHz) transient: hi-hat / shaker
    var snareCount: UInt64 = 0
    var hatCount: UInt64 = 0
    var centroid: Float = 0         // spectral centroid, normalised 0 (dark) ... 1 (bright) — maps to haptic sharpness
    var flux: Float = 0             // full-band spectral flux 0...1 (texture / roughness)
    var lastSnareTime: Double = 0   // hostNow() estimate of the most recent snare transient (same convention as lastOnsetTime)
    var lastHatTime: Double = 0     // same for hats
}

/// Where system audio comes from. Both capture the Mac's output digitally (what screen recorders do);
/// neither needs BlackHole, a Multi-Output device or the microphone.
enum AudioSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case processTap      // Core Audio process tap — "System Audio Recording Only" permission (lowest latency)
    case screenCapture   // ScreenCaptureKit audio stream — "Screen & System Audio Recording" permission
    var id: String { rawValue }
    var title: String { self == .processTap ? "System Audio Tap" : "Screen Capture Audio" }
}

/// Audio-to-ear delay. Capture sees samples before the output device plays them (built-in speakers
/// ≈ 10–30 ms, Bluetooth ≈ 150–250 ms), so anything synced to the music (glow, haptics) must land
/// `delay` seconds after the analyzer saw the event. Key-driven effects are local and never delayed.
/// Written by OutputLatency (device latency) and AppModel (user settings); read on any thread.
final class SyncClock: @unchecked Sendable {
    static let shared = SyncClock()
    private let lock = UnfairLock()
    private var _output: Double = 0
    private var _offset: Double = 0
    private var _auto = true

    /// Measured latency of the default output device in seconds (device + safety offset + buffer + stream).
    var outputLatency: Double {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = max(0, min(newValue, 1)) } }
    }
    /// User fine-tune in seconds, positive = later. Applied on top of the measured latency.
    var userOffset: Double {
        get { lock.withLock { _offset } }
        set { lock.withLock { _offset = max(-0.3, min(newValue, 0.3)) } }
    }
    /// When false, only `userOffset` is used.
    var autoLatency: Bool {
        get { lock.withLock { _auto } }
        set { lock.withLock { _auto = newValue } }
    }
    /// Seconds to hold music-driven events after capture. Never negative.
    var delay: Double { lock.withLock { max(0, (_auto ? _output : 0) + _offset) } }
}

final class FeatureBus: @unchecked Sendable {
    static let shared = FeatureBus()

    private let lock = UnfairLock()
    private var _latest = AudioFeatures()
    private var listeners: [(id: Int, fn: (AudioFeatures) -> Void)] = []
    private var nextID = 1
    private var _cutoffHz: Float = 120
    private var _sensitivity: Float = 1
    // History ring (~6 s of frames, preallocated; written under `lock`, no allocation per publish).
    private static let ringCap = 1536
    private let ring: UnsafeMutablePointer<AudioFeatures> = {
        let p = UnsafeMutablePointer<AudioFeatures>.allocate(capacity: FeatureBus.ringCap)
        p.initialize(repeating: AudioFeatures(), count: FeatureBus.ringCap)
        return p
    }()
    private var ringHead = 0        // next write slot
    private var ringCount = 0

    /// Haptic/bass crossover the analyzer uses for `belowCutoff` / `bassPitchHz`. Set by AppModel.
    var cutoffHz: Float {
        get { lock.withLock { _cutoffHz } }
        set { lock.withLock { _cutoffHz = max(40, min(400, newValue)) } }
    }
    /// Onset sensitivity multiplier 0.25...3 (higher = more onsets). Set by AppModel.
    var sensitivity: Float {
        get { lock.withLock { _sensitivity } }
        set { lock.withLock { _sensitivity = max(0.25, min(3, newValue)) } }
    }

    /// Called by the analyzer on the audio thread.
    func publish(_ f: AudioFeatures) {
        lock.lock()
        _latest = f
        ring[ringHead] = f
        ringHead = (ringHead + 1) % FeatureBus.ringCap
        if ringCount < FeatureBus.ringCap { ringCount += 1 }
        let ls = listeners
        lock.unlock()
        for l in ls { l.fn(f) }
    }

    /// The frame the listener hears "now" when the output path adds `seconds` of latency: the newest
    /// frame with `time <= now - seconds`. `seconds <= 0` returns the latest frame. Frames are real
    /// published frames, so onsetCount / lastOnsetTime stay coherent. Before enough history exists
    /// (or the ring is empty) a silent frame is returned.
    func delayed(_ seconds: Double, now: Double = hostNow()) -> AudioFeatures {
        lock.lock(); defer { lock.unlock() }
        if ringCount == 0 { return AudioFeatures() }
        if now - _latest.time > 0.6 { return AudioFeatures() }   // analyzer stopped publishing: go dark
        if seconds <= 0 { return _latest }
        let target = now - seconds
        let cap = FeatureBus.ringCap
        let oldest = (ringHead - ringCount + cap) % cap
        if ring[oldest].time > target { return AudioFeatures() }
        var lo = 0, hi = ringCount - 1
        while lo < hi {   // times are monotonic: find newest index with time <= target
            let mid = (lo + hi + 1) >> 1
            if ring[(oldest + mid) % cap].time <= target { lo = mid } else { hi = mid - 1 }
        }
        return ring[(oldest + lo) % cap]
    }

    /// Latest frame (any thread).
    func latest() -> AudioFeatures { lock.withLock { _latest } }

    /// Register a listener invoked synchronously on the analysis thread. Returns a token.
    @discardableResult
    func subscribe(_ fn: @escaping (AudioFeatures) -> Void) -> Int {
        lock.withLock { let id = nextID; nextID += 1; listeners.append((id, fn)); return id }
    }
    func unsubscribe(_ token: Int) { lock.withLock { listeners.removeAll { $0.id == token } } }

    /// Mark the stream as silent (e.g. tap stopped). Keeps counters.
    func markSilent() { lock.withLock { _latest.silent = true; _latest.level = 0; _latest.bands = .init(); _latest.belowCutoff = 0 } }
}

// MARK: - Keys

enum KeyKind: Int, Sendable, Codable {
    case generic, space, enter, backspace, tab, escape, modifier, function, arrow, capsLock, fn
}

/// One physical key event. `x`,`y` are normalised positions on the MacBook keyboard
/// (x: 0 = left edge, 1 = right edge; y: 0 = top/function row, 1 = bottom row).
struct KeyEvent: Sendable {
    var keyCode: UInt16
    var down: Bool
    var isRepeat: Bool
    var time: Double          // hostNow() at capture
    var kind: KeyKind
    var row: Int              // 0 = function row ... 5 = space row
    var x: Float
    var y: Float
}

/// A keycap of the on-screen MacBook keyboard (ANSI, no numpad). Geometry in key units:
/// main keys are 1×1, the function row is shorter; the full board is `KeyLayout.size` units.
struct KeyCap: Identifiable, Sendable {
    let id: Int
    let keyCode: UInt16        // 0xFFFF for caps with no keycode (e.g. Touch ID)
    let label: String
    let rect: CGRect           // in key units, origin top-left
    let kind: KeyKind
    let row: Int
}

final class KeyBus: @unchecked Sendable {
    static let shared = KeyBus()
    private let lock = UnfairLock()
    private var listeners: [(id: Int, fn: (KeyEvent) -> Void)] = []
    private var nextID = 1
    private var _lastEvent: KeyEvent?
    private var downTimes: [Double] = []   // recent key-down times for keys-per-minute

    func publish(_ e: KeyEvent) {
        lock.lock()
        _lastEvent = e
        if e.down && !e.isRepeat {
            downTimes.append(e.time)
            if downTimes.count > 512 { downTimes.removeFirst(downTimes.count - 512) }
        }
        let ls = listeners
        lock.unlock()
        for l in ls { l.fn(e) }
    }
    func lastEvent() -> KeyEvent? { lock.withLock { _lastEvent } }
    /// Key-downs in the last 60 s (excluding repeats).
    func keysPerMinute(now: Double = hostNow()) -> Int { lock.withLock { downTimes.filter { now - $0 < 60 }.count } }

    @discardableResult
    func subscribe(_ fn: @escaping (KeyEvent) -> Void) -> Int {
        lock.withLock { let id = nextID; nextID += 1; listeners.append((id, fn)); return id }
    }
    func unsubscribe(_ token: Int) { lock.withLock { listeners.removeAll { $0.id == token } } }
}

/// Haptic actuation notifications for the UI trackpad glyph.
final class HapticBus: @unchecked Sendable {
    static let shared = HapticBus()
    private let lock = UnfairLock()
    private var _lastHit: Double = 0
    private var _lastLevel: Float = 0
    func noteHit(level: Float, time: Double = hostNow()) { lock.withLock { _lastHit = time; _lastLevel = level } }
    func lastHit() -> (time: Double, level: Float) { lock.withLock { (_lastHit, _lastLevel) } }
}

// MARK: - Glow (keyboard backlight)

enum GlowMode: String, CaseIterable, Codable, Sendable, Identifiable {
    // music-reactive
    case beatPulse      // flare to ceiling on each onset, musical decay (MagicKey "Audio Beat", improved)
    case bassFollow     // brightness follows bass envelope continuously
    case beatStrobe     // sharp short flash on each onset
    case metronome      // BPM-locked pulse on predicted beats
    case spectrum       // bass body + treble sparkle mix
    // typing-reactive
    case keyPulse       // flare on each key press (repeat filtered)
    case typingHeat     // brightness builds with typing speed, cools when idle
    // ambient
    case steady         // constant level
    case breathe        // slow cosine breathing
    case heartbeat      // lub-dub
    case candle         // warm flicker
    case aurora         // slow layered waves
    case lightning      // random storm flashes
    case sleep          // breathing that slows and fades to off over `sleepMinutes`
    case off

    var id: String { rawValue }
}

struct GlowConfig: Sendable, Equatable, Codable {
    var enabled: Bool = true
    var mode: GlowMode = .beatPulse
    var floor: Float = 0.0          // 0...1 minimum level
    var ceiling: Float = 1.0        // 0...1 maximum level (1.0 = full hardware brightness)
    var speed: Float = 1.0          // 0.25...4 time scale for ambient modes / decay length for reactive
    var sensitivity: Float = 1.0    // 0.25...3 reactive gain
    var keyFlash: Bool = true       // overlay a flash on key presses in any mode
    var keepAwake: Bool = true      // suspend macOS 5 s idle-dim while running
    var sleepMinutes: Float = 15    // for .sleep
    var steadyLevel: Float = 0.6    // for .steady
    /// `mode` is the music mode. With autoSwitch on, the engine renders `mode` while music plays and
    /// `idleMode` otherwise (crossfaded); with it off, `mode` only.
    var autoSwitch: Bool = true
    var idleMode: GlowMode = .breathe
    /// Mirror the glow on a connected Logitech keyboard (MX Keys family, HID++ BACKLIGHT2).
    var logitech: Bool = true
    /// Heartbeat mode: the pulse rate follows system CPU load (resting when idle, racing under load).
    var heartFollowsCPU: Bool = true

    /// True for the five music-reactive modes. Typing and ambient modes never take part in auto switching.
    static func isMusicMode(_ m: GlowMode) -> Bool {
        switch m {
        case .beatPulse, .bassFollow, .beatStrobe, .metronome, .spectrum: return true
        default: return false
        }
    }
    /// Auto switching is in effect only when it is on and `mode` is a music mode.
    var autoActive: Bool { autoSwitch && GlowConfig.isMusicMode(mode) }

    enum CodingKeys: String, CodingKey {
        case enabled, mode, floor, ceiling, speed, sensitivity, keyFlash, keepAwake, sleepMinutes, steadyLevel
        case autoSwitch, idleMode, logitech, heartFollowsCPU
    }
}

extension GlowConfig {
    /// Tolerant decoding: fields missing from older saved JSON keep their defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ d: Float, _ lo: Float, _ hi: Float) -> Float {
            guard let v = (try? c.decodeIfPresent(Float.self, forKey: k)) ?? nil, v.isFinite else { return d }
            return min(hi, max(lo, v))
        }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? enabled
        mode = (try? c.decodeIfPresent(GlowMode.self, forKey: .mode)) ?? mode
        floor = f(.floor, floor, 0, 1)
        ceiling = f(.ceiling, ceiling, 0.05, 1)
        speed = f(.speed, speed, 0.25, 4)
        sensitivity = f(.sensitivity, sensitivity, 0.25, 3)
        keyFlash = (try? c.decodeIfPresent(Bool.self, forKey: .keyFlash)) ?? keyFlash
        keepAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwake)) ?? keepAwake
        logitech = (try? c.decodeIfPresent(Bool.self, forKey: .logitech)) ?? logitech
        heartFollowsCPU = (try? c.decodeIfPresent(Bool.self, forKey: .heartFollowsCPU)) ?? heartFollowsCPU
        sleepMinutes = f(.sleepMinutes, sleepMinutes, 1, 60)
        steadyLevel = f(.steadyLevel, steadyLevel, 0, 1)
        // configs saved before auto switching existed keep their behaviour: auto only for music modes
        autoSwitch = (try? c.decodeIfPresent(Bool.self, forKey: .autoSwitch)) ?? GlowConfig.isMusicMode(mode)
        idleMode = (try? c.decodeIfPresent(GlowMode.self, forKey: .idleMode)) ?? idleMode
        if floor > ceiling { floor = ceiling }
    }
}

// MARK: - Haptics (Force Touch trackpad)

enum HapticMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case music       // Apple Music Haptics-style: taps (kick/snare/hat), bass texture, refined melody vibration
    case movie       // Cinema LFE-style: big impacts and sustained sub-bass rumble, silent during dialogue
    case kick        // nospeaker-style pitch-drop thump on each low-band onset
    case bass        // stream bass below cutoff to the motor (folded up into motor range)
    case full        // "pure trackpad": motor plays the music's two strongest peaks
    case off
    var id: String { rawValue }
}

struct HapticConfig: Sendable, Equatable, Codable {
    var enabled: Bool = true
    var mode: HapticMode = .music
    var texture: Float = 0.5        // 0...1 music mode: amount of continuous bass/sustain texture under the taps
    var detail: Float = 0.5         // 0...1 music mode: how many small taps (snare/hats/melody) vs kicks only
    var rumble: Float = 0.75        // 0...1 movie mode: sustained sub-bass rumble intensity
    var strength: Float = 0.8       // 0...1 (maps to MTActuationActuate level, never > 1)
    var cutoffHz: Float = 120       // 40...250 bass crossover (also FeatureBus.cutoffHz)
    var punch: Float = 0.5          // 0...1 kick: decay length / bass: attack sharpness
    var pitch: Float = 0.5          // 0...1 kick start/end pitch, bass octave fold target
    var typingTaps: Bool = false    // light tap on each key press
    var preferExternal: Bool = false // use Magic Trackpad instead of built-in
    var feel: HapticFeel = .deep    // character of kick/tap voices
    var quiet: Bool = true          // keep the glass inaudible: low tones, smooth envelopes, no system clicks
    /// Auto: while `mode` is music or movie, pick Music or Movie from what is playing (see AudioSourceMonitor).
    var autoSource: Bool = true

    enum CodingKeys: String, CodingKey {
        case enabled, mode, texture, detail, rumble, strength, cutoffHz, punch, pitch
        case typingTaps, preferExternal, feel, quiet, autoSource
    }
}

extension HapticConfig {
    /// Tolerant decoding: fields missing from older saved JSON keep their defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ d: Float, _ lo: Float, _ hi: Float) -> Float {
            guard let v = (try? c.decodeIfPresent(Float.self, forKey: k)) ?? nil, v.isFinite else { return d }
            return min(hi, max(lo, v))
        }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? d }
        enabled = b(.enabled, enabled)
        mode = (try? c.decodeIfPresent(HapticMode.self, forKey: .mode)) ?? mode
        texture = f(.texture, texture, 0, 1)
        detail = f(.detail, detail, 0, 1)
        rumble = f(.rumble, rumble, 0, 1)
        strength = f(.strength, strength, 0, 1)
        cutoffHz = f(.cutoffHz, cutoffHz, 40, 250)
        punch = f(.punch, punch, 0, 1)
        pitch = f(.pitch, pitch, 0, 1)
        typingTaps = b(.typingTaps, typingTaps)
        preferExternal = b(.preferExternal, preferExternal)
        feel = (try? c.decodeIfPresent(HapticFeel.self, forKey: .feel)) ?? feel
        quiet = b(.quiet, quiet)
        autoSource = b(.autoSource, autoSource)
    }
}

/// Character of the kick/tap voices. All three respect `HapticConfig.quiet`.
enum HapticFeel: String, CaseIterable, Codable, Sendable, Identifiable {
    case deep      // low, rounded body thump (felt more than heard)
    case punchy    // tighter, slightly higher thump
    case crisp     // short sharp taps (most audible; quiet mode softens it)
    var id: String { rawValue }
    var title: String { switch self { case .deep: "Deep"; case .punchy: "Punchy"; case .crisp: "Crisp" } }
}

/// Audio-to-ear sync settings (see SyncClock).
struct SyncConfig: Sendable, Equatable, Codable {
    var auto: Bool = true           // use the output device's reported latency
    var offsetMs: Double = 0        // fine-tune, -300...300 ms, positive = later

    enum CodingKeys: String, CodingKey { case auto, offsetMs }
    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auto = ((try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? nil) ?? auto
        if let v = (try? c.decodeIfPresent(Double.self, forKey: .offsetMs)) ?? nil, v.isFinite { offsetMs = min(300, max(-300, v)) }
    }
}

// MARK: - Key sounds

struct SoundPack: Identifiable, Sendable, Hashable {
    let id: String          // folder name under Sounds/
    let name: String        // e.g. "Holy Panda"
    let character: String   // e.g. "Thocky"
}

struct SoundConfig: Sendable, Equatable, Codable {
    var enabled: Bool = true
    var packID: String = "holypanda"
    var volume: Float = 0.7         // 0...1
    var spatial: Float = 0.8        // 0...1 stereo spread by key position
    var pitchVariation: Float = 0.5 // 0...1 (1 = ±0.6 semitone)
    var releaseSounds: Bool = true
    var modifierSounds: Bool = true

    enum CodingKeys: String, CodingKey { case enabled, packID, volume, spatial, pitchVariation, releaseSounds, modifierSounds }
    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ d: Float) -> Float {
            guard let v = (try? c.decodeIfPresent(Float.self, forKey: k)) ?? nil, v.isFinite else { return d }
            return min(1, max(0, v))
        }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? d }
        enabled = b(.enabled, enabled)
        if let v = (try? c.decodeIfPresent(String.self, forKey: .packID)) ?? nil { packID = v }
        volume = f(.volume, volume)
        spatial = f(.spatial, spatial)
        pitchVariation = f(.pitchVariation, pitchVariation)
        releaseSounds = b(.releaseSounds, releaseSounds)
        modifierSounds = b(.modifierSounds, modifierSounds)
    }
}

// MARK: - Engine status for UI

enum EngineStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case needsPermission(String)   // human-readable which permission
    case unavailable(String)       // hardware/API missing
    case failed(String)

    var isRunning: Bool { if case .running = self { return true }; return false }
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .needsPermission(let p): return "Needs \(p)"
        case .unavailable(let r): return r
        case .failed(let r): return r
        }
    }
}

/// System-audio capture state (from SystemAudioTap).
enum AudioInputState: Equatable, Sendable {
    case inactive, starting, active, idleNoAudio, stalled, needsPermission, unsupported, failed(String)
    var label: String {
        switch self {
        case .inactive: return "Off"
        case .starting: return "Connecting…"
        case .active: return "Listening"
        case .idleNoAudio: return "Waiting for audio"
        case .stalled: return "Stalled"
        case .needsPermission: return "Needs System Audio Recording"
        case .unsupported: return "Requires macOS 14.2"
        case .failed(let s): return s
        }
    }
}

// MARK: - Logging

enum Log {
    static let logger = Logger(subsystem: "com.hapticglow.mac", category: "app")
    private static let fileLock = UnfairLock()
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/HapticGlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hapticglow.log")
    }()
    /// Not for realtime threads. Writes to unified log + ~/Library/Logs/HapticGlow/hapticglow.log
    static func write(_ msg: String) {
        logger.log("\(msg, privacy: .public)")
        let line = "[\(String(format: "%.3f", hostNow()))] \(msg)\n"
        let data = Data(line.utf8)
        fileLock.withLock {
            if let h = try? FileHandle(forWritingTo: fileURL) {
                let size = h.seekToEndOfFile()
                if size >= maxFileBytes {
                    try? h.close()
                    let old = fileURL.deletingLastPathComponent().appendingPathComponent("hapticglow.1.log")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: fileURL, to: old)
                    try? data.write(to: fileURL)
                } else {
                    h.write(data); try? h.close()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
    /// The log rolls over to hapticglow.1.log (one old file kept) past this size.
    private static let maxFileBytes: UInt64 = 2 * 1024 * 1024
}
