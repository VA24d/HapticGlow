// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Low-latency spatial key-sound engine.
//
// Credits: sound packs are from kbsim (MIT, tplai, https://github.com/tplai/kbsim); see Sounds/CREDITS.md.
// Soft-clip curve and pan law derive from Thock (MIT, kamillobinski); always-on stream, fixed voice
// pool and no-queue-hop idea refined from Thock/Clacky (MIT).
//
// Realtime design: KeyBus listener (tap thread) resolves sample/pan/pitch/gain, then writes a POD event
// into an SPSC ring. The AVAudioSourceNode render block drains the ring, starts voices and mixes with
// raw pointers only (no allocation, locks, logging or ObjC messaging).
//
// Two output paths share that core. Plain: one stereo RT instance (pan by key x) -> main mixer.
// Spatial: SpatialLaneCount mono RT instances, one per fixed position across the keyboard, each feeding an
// AVAudioEnvironmentNode source (speaker rendering on built-in speakers, HRTFHQ on headphones), then a peak
// limiter (see Sources/Audio/OutputRoute.swift). Built-in speakers also get a psychoacoustic bass
// enhancer and a mild low shelf inside the RT mix.
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Observation
import Synchronization

// MARK: - Realtime core

/// Render-thread counters, readable from any thread (Double values stored as bit patterns).
private final class RTStats: @unchecked Sendable {
    let latencyBits = Atomic<UInt64>(0)
    let delayBits = Atomic<UInt64>(0)
    let events = Atomic<UInt64>(0)
    let buffers = Atomic<UInt64>(0)
}

private struct RTEvent {
    var ptr: UnsafePointer<Float>? = nil
    var len: Int32 = 0
    var rate: Float = 1
    var gL: Float = 0
    var gR: Float = 0
    var time: Double = 0
}

private struct Voice {
    var ptr: UnsafePointer<Float>? = nil
    var len: Int = 0
    var pos: Double = 0
    var rate: Double = 1
    var gL: Float = 0
    var gR: Float = 0
    var seq: UInt64 = 0
    var fadeLeft: Int32 = 0
    var fadeTotal: Int32 = 0   // >0 = fading out (stolen)
}

/// RBJ biquad, transposed direct form II.
private struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
    private mutating func set(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }
    static func bandpass(_ f: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, al = sin(w) / (2 * q), c = cos(w)
        var b = Biquad(); b.set(al, 0, -al, 1 + al, -2 * c, 1 - al); return b
    }
    static func highpass(_ f: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, al = sin(w) / (2 * q), c = cos(w)
        var b = Biquad(); b.set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al); return b
    }
    static func lowShelf(_ f: Double, gainDB: Double, rate: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w)
        let al = sin(w) / 2 * (2.0).squareRoot(), sq = 2 * A.squareRoot() * al
        var b = Biquad()
        b.set(A * ((A + 1) - (A - 1) * c + sq), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sq),
              (A + 1) + (A - 1) * c + sq, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sq)
        return b
    }
}

private final class RT: @unchecked Sendable {
    static let ringCap = 256
    static let normalVoices = 32
    static let totalVoices = 40
    static let fadeFrames: Int32 = 240   // 5 ms @ 48 kHz

    let ring = UnsafeMutablePointer<RTEvent>.allocate(capacity: RT.ringCap)
    let head = Atomic<Int>(0)
    let tail = Atomic<Int>(0)
    let voices = UnsafeMutablePointer<Voice>.allocate(capacity: RT.totalVoices)
    var seq: UInt64 = 0
    /// Seconds per mach tick.
    let tickSec: Double
    // Stats written by the render thread, read by anyone (may be shared between instances).
    fileprivate let stats: RTStats
    /// Gain applied after the soft clip (system volume compensation), so boosted peaks are not squashed.
    let postGain = Atomic<UInt32>(Float(1).bitPattern)
    // Speaker tuning (per channel: band-pass, harmonic high-pass, low shelf). Configured only while stopped.
    private let tuneState = UnsafeMutablePointer<Biquad>.allocate(capacity: 6)
    private var tune = false
    private var bassAmount: Float = 0.45
    static let scratchCap = 16384
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: RT.scratchCap)

    fileprivate init(stats shared: RTStats? = nil) {
        ring.initialize(repeating: RTEvent(), count: RT.ringCap)
        voices.initialize(repeating: Voice(), count: RT.totalVoices)
        tuneState.initialize(repeating: Biquad(), count: 6)
        scratch.initialize(repeating: 0, count: RT.scratchCap)
        stats = shared ?? RTStats()
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        tickSec = Double(tb.numer) / Double(tb.denom) / 1e9
    }
    deinit {
        ring.deallocate(); voices.deallocate(); tuneState.deallocate(); scratch.deallocate()
    }

    /// Configure speaker tuning for `rate`. Only call while the render callback is stopped.
    func configureTuning(rate: Double, enabled: Bool) {
        tune = enabled
        for c in 0..<2 {
            tuneState[c * 3] = .bandpass(113, q: 1.4, rate: rate)       // 80-160 Hz body
            tuneState[c * 3 + 1] = .highpass(230, q: 0.7, rate: rate)   // keep harmonics, drop the fundamental
            tuneState[c * 3 + 2] = .lowShelf(180, gainDB: 2, rate: rate)
        }
    }

    /// Mono lane render for the spatial path.
    func renderMono(frames: Int, hostTime: UInt64, buf: UnsafeMutablePointer<Float>) -> Bool {
        if frames > RT.scratchCap { for n in 0..<frames { buf[n] = 0 }; return false }
        return render(frames: frames, hostTime: hostTime, left: buf, right: scratch, channels: 1)
    }

    /// Drop queued events and silence all voices. Only call while the render callback is stopped.
    func resetForRestart() {
        head.store(tail.load(ordering: .relaxed), ordering: .releasing)
        for i in 0..<RT.totalVoices { voices[i] = Voice() }
    }

    /// Producer side (callers serialised by `spin`).
    @inline(__always) func push(_ e: RTEvent) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        if t &- h >= RT.ringCap { return }
        ring[t & (RT.ringCap - 1)] = e
        tail.store(t &+ 1, ordering: .releasing)
    }

    private func startVoice(_ e: RTEvent) {
        guard let p = e.ptr, e.len > 1 else { return }
        var free = -1, normal = 0, oldest = -1, oldestSeq = UInt64.max
        for i in 0..<RT.totalVoices {
            let v = voices[i]
            if v.ptr == nil { if free < 0 { free = i } }
            else if v.fadeTotal == 0 {
                normal += 1
                if v.seq < oldestSeq { oldestSeq = v.seq; oldest = i }
            }
        }
        if normal >= RT.normalVoices && oldest >= 0 {
            voices[oldest].fadeTotal = RT.fadeFrames
            voices[oldest].fadeLeft = RT.fadeFrames
        }
        if free < 0 {
            // pool exhausted by fades: hard-replace the oldest voice of any kind
            var o = 0, os = UInt64.max
            for i in 0..<RT.totalVoices where voices[i].seq < os { os = voices[i].seq; o = i }
            free = o
        }
        seq &+= 1
        voices[free] = Voice(ptr: p, len: Int(e.len), pos: 0, rate: Double(e.rate), gL: e.gL, gR: e.gR,
                             seq: seq, fadeLeft: 0, fadeTotal: 0)
    }

    func render(frames: Int, hostTime: UInt64, left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>, channels: Int = 2) -> Bool {
        // 1. drain events
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if h != t {
            let nowTicks = mach_absolute_time()
            while h != t {
                let e = ring[h & (RT.ringCap - 1)]
                h &+= 1
                startVoice(e)
                let ts = hostTime != 0 ? hostTime : nowTicks
                stats.latencyBits.store((Double(ts) * tickSec - e.time).bitPattern, ordering: .relaxed)
                stats.delayBits.store((Double(nowTicks) * tickSec - e.time).bitPattern, ordering: .relaxed)
                stats.events.wrappingAdd(1, ordering: .relaxed)
            }
            head.store(h, ordering: .releasing)
        }
        stats.buffers.wrappingAdd(1, ordering: .relaxed)

        // 2. mix
        var any = false
        for i in 0..<RT.totalVoices where voices[i].ptr != nil { any = true; break }
        for n in 0..<frames { left[n] = 0; right[n] = 0 }
        if !any {
            if tune { for k in 0..<6 { tuneState[k].z1 = 0; tuneState[k].z2 = 0 } }
            return false
        }

        for i in 0..<RT.totalVoices {
            guard let p = voices[i].ptr else { continue }
            var pos = voices[i].pos
            let rate = voices[i].rate
            let len = voices[i].len
            let gL = voices[i].gL, gR = voices[i].gR
            var fl = voices[i].fadeLeft
            let ft = voices[i].fadeTotal
            let invFt: Float = ft > 0 ? 1 / Float(ft) : 0
            var n = 0
            var dead = false
            while n < frames {
                let idx = Int(pos)
                if idx >= len - 1 { dead = true; break }
                let frac = Float(pos - Double(idx))
                let a = p[idx]
                var s = a + (p[idx + 1] - a) * frac
                if ft > 0 {
                    if fl <= 0 { dead = true; break }
                    s *= Float(fl) * invFt
                    fl -= 1
                }
                left[n] += s * gL
                right[n] += s * gR
                pos += rate
                n += 1
            }
            if dead { voices[i].ptr = nil; voices[i].fadeTotal = 0 }
            else { voices[i].pos = pos; voices[i].fadeLeft = fl }
        }

        // 3. Speaker tuning: psychoacoustic bass (odd harmonics of the 80-160 Hz band) + mild low shelf
        if tune {
            let amt = bassAmount
            for c in 0..<channels {
                let buf = c == 0 ? left : right
                for n in 0..<frames {
                    let x = buf[n]
                    let body = tuneState[c * 3].process(x)
                    let harm = tuneState[c * 3 + 1].process(tanhf(3 * body))
                    buf[n] = tuneState[c * 3 + 2].process(x) + amt * harm
                }
            }
        }

        // 4. Thock soft clip (knee 0.7, asymptote -1 dBFS)
        for n in 0..<frames { left[n] = RT.softClip(left[n]) }
        if channels > 1 { for n in 0..<frames { right[n] = RT.softClip(right[n]) } }
        let pg = Float(bitPattern: postGain.load(ordering: .relaxed))
        if pg != 1 {
            for n in 0..<frames { left[n] *= pg }
            if channels > 1 { for n in 0..<frames { right[n] *= pg } }
        }
        return true
    }

    @inline(__always) static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.7 { return x }
        let e = a - 0.7
        let y = 0.7 + 0.19 * e / (e + 0.19)
        return x < 0 ? -y : y
    }
}

// MARK: - Pack data

private final class PackData: @unchecked Sendable {
    static let names = ["GENERIC_R0", "GENERIC_R1", "GENERIC_R2", "GENERIC_R3", "GENERIC_R4",
                        "SPACE", "ENTER", "BACKSPACE", "ESC"]          // press 0...8
    static let relNames = ["GENERIC", "SPACE", "ENTER", "BACKSPACE", "ESC"] // release 9...13

    let id: String
    let rate: Double
    let slab: UnsafeMutablePointer<Float>
    let slabCount: Int
    let off: [Int]       // 14 entries
    let len: [Int32]     // 14 entries
    let lead: [Int]      // trimmed leading samples per sample
    let normGain: Float
    init(id: String, rate: Double, slab: UnsafeMutablePointer<Float>, count: Int, off: [Int], len: [Int32],
         lead: [Int], normGain: Float) {
        self.id = id; self.rate = rate; self.slab = slab; slabCount = count
        self.off = off; self.len = len; self.lead = lead; self.normGain = normGain
    }
    deinit { slab.deallocate() }
    var bytes: Int { slabCount * 4 }
}

/// Key-sound settings. Packed into one 64-bit word (three 16-bit fixed-point 0...1 values plus flags) so the
/// UI thread can publish a whole snapshot with a single atomic store and the key thread reads it without a lock.
private struct CfgPOD {
    var enabled = true
    var volume: Float = 0.7
    var spatial: Float = 0.8
    var pitchVar: Float = 0.5
    var release = true
    var modifiers = true

    init(enabled: Bool = true, volume: Float = 0.7, spatial: Float = 0.8, pitchVar: Float = 0.5,
         release: Bool = true, modifiers: Bool = true) {
        self.enabled = enabled; self.volume = volume; self.spatial = spatial; self.pitchVar = pitchVar
        self.release = release; self.modifiers = modifiers
    }

    private static func q(_ v: Float) -> UInt64 { UInt64((max(0, min(1, v)) * 65535).rounded()) }
    private static func d(_ b: UInt64) -> Float { Float(b & 0xFFFF) / 65535 }

    var bits: UInt64 {
        Self.q(volume) | Self.q(spatial) << 16 | Self.q(pitchVar) << 32
            | (enabled ? 1 << 48 : 0) | (release ? 1 << 49 : 0) | (modifiers ? 1 << 50 : 0)
    }
    init(bits b: UInt64) {
        volume = Self.d(b); spatial = Self.d(b >> 16); pitchVar = Self.d(b >> 32)
        enabled = b & (1 << 48) != 0; release = b & (1 << 49) != 0; modifiers = b & (1 << 50) != 0
    }
}

private func devProp<T: BitwiseCopyable>(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope, _ zero: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

private func outProp<T: BitwiseCopyable>(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                         _ element: AudioObjectPropertyElement, _ zero: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    guard AudioObjectHasProperty(dev, &addr) else { return nil }
    var v = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

/// Persisted list of pinned favourite sound pack IDs. Pre-pins `cream` and `alpaca` on first run.
@Observable
final class SoundPinStore: @unchecked Sendable {
    static let shared = SoundPinStore()
    static let defaultKey = "hapticglow.pinnedPacks.v1"
    static let defaultPinned: [String] = ["cream", "alpaca"]

    private let defaults: UserDefaults
    private let key: String
    private(set) var pinnedIDs: [String]

    init(defaults: UserDefaults = .standard, key: String = SoundPinStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        if let arr = defaults.stringArray(forKey: key) {
            self.pinnedIDs = arr
        } else {
            self.pinnedIDs = Self.defaultPinned
            defaults.set(Self.defaultPinned, forKey: key)
        }
    }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func toggle(_ id: String) {
        if let i = pinnedIDs.firstIndex(of: id) {
            pinnedIDs.remove(at: i)
        } else {
            pinnedIDs.append(id)
        }
        defaults.set(pinnedIDs, forKey: key)
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard isPinned(id) != pinned else { return }
        toggle(id)
    }
}

/// What the key-sound engine is actually doing with the current output, for the UI.
struct KeySoundRoute: Sendable, Equatable {
    var output = OutputRouteInfo()
    var spatial = false
    /// Why spatial rendering is not in use (nil when it is, or when the user switched it off).
    var note: String?
    /// Measured latency added by the spatial chain versus the plain path, ms (nil if not measured).
    var addedLatencyMs: Double?

    /// e.g. "MacBook Pro Speakers · spatial" / "soundcore Q20i · Bluetooth, stereo".
    var summary: String {
        guard output.kind != .none else { return "No output device" }
        let name = output.label
        if spatial { return "\(name) · spatial" }
        switch output.kind {
        case .bluetooth: return "\(name) · Bluetooth, stereo"
        case .airPlay: return "\(name) · AirPlay, stereo"
        case .wiredHeadphones: return "\(name) · headphones, stereo"
        default: return "\(name) · stereo"
        }
    }
}

// MARK: - Engine

final class KeySoundEngine: @unchecked Sendable {
    static let shared = KeySoundEngine()

    /// Bundle `Resources/Sounds`, falling back to the repo `HapticGlow_App/Sounds` in dev runs.
    static var soundsDirectory: URL {
        let fm = FileManager.default
        var cands: [URL] = []
        if let r = Bundle.main.resourceURL { cands.append(r.appendingPathComponent("Sounds")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        cands.append(exe.appendingPathComponent("../../Sounds").standardized)
        cands.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Sounds"))
        for c in cands where fm.fileExists(atPath: c.appendingPathComponent("holypanda").path) { return c }
        return cands[0]
    }

    private static let meta: [(id: String, name: String, character: String)] = [
        ("holypanda", "Holy Panda", "Thocky"), ("topre", "Topre", "Dense"),
        ("boxnavy", "Box Navy", "Crisp"), ("bluealps", "SKCM Blue Alps", "Clacky"),
        ("buckling", "IBM Buckling Spring", "Classic"), ("cream", "NovelKeys Cream", "Full"),
        ("blackink", "Gateron Ink Black", "Deep"), ("mxblack", "Cherry MX Black", "Muted"),
        ("redink", "Gateron Ink Red", "Rounded"), ("turquoise", "Tealios", "Smooth"),
        ("mxbrown", "Cherry MX Brown", "Gentle"), ("alpaca", "Alpaca", "Quiet"),
    ]

    private let sharedStats = RTStats()
    private let rt: RT
    private let laneRT: [RT]
    /// 0 = plain stereo path, 1 = spatial lanes. Written on ctl while stopped, read by producers.
    private let mode = Atomic<Int>(0)
    private var chain: SpatialChain?
    private var routeSub: Int?
    private var builtKind: OutputKind = .none
    private var builtCall = false
    private var lastSpread: Float = -1
    /// Producer gain for spatial lanes; set on ctl before `mode` flips to 1 (release/acquire pairs it).
    private var laneGain: Float = SpatialChain.laneTrim
    private let routeBox = Locked(KeySoundRoute())
    private let cfgBits = Atomic<UInt64>(CfgPOD().bits)
    private var cfgNow: CfgPOD { CfgPOD(bits: cfgBits.load(ordering: .acquiring)) }
    private func setCfg(_ c: CfgPOD) { cfgBits.store(c.bits, ordering: .releasing) }
    private let ctl = DispatchQueue(label: "HapticGlow.KeySound.ctl", qos: .userInitiated)
    private let statusBox = Locked<EngineStatus>(.stopped)
    private let packsBox = Locked<[SoundPack]?>(nil)
    private let packID = Locked<String>("holypanda")

    // Pack publication: producer reads unretained pointer bits; strong refs live in ctl-owned vars.
    private let packBits = Atomic<Int>(0)
    private var currentPack: PackData?
    private var retired: [(PackData, Double)] = []
    private var prunePending = false

    // Producer-side state, serialised by `spin`.
    private let spin = Atomic<Bool>(false)
    private var rng: UInt64 = 0x9E3779B97F4A7C15
    private var lastPitchSt: Float = 99
    private var lastDownCode: UInt16 = 0xFFFF
    private var lastDownTime: Double = 0

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var busToken: Int?
    private var running = false
    private var rebuildPending = false
    private var startRetryPending = false
    private var powerObs: NSObjectProtocol?
    private var idleTimer: DispatchSourceTimer?
    private let idleStopped = Atomic<Bool>(false)
    private let lastKeyBits = Atomic<UInt64>(0)
    private static let idleStopAfter: Double = 60
    private var devListener: AudioObjectPropertyListenerBlock?
    private var volDevice: AudioObjectID = 0
    private var volListener: AudioObjectPropertyListenerBlock?
    private let sysGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private var bufFrames = 0
    private var outRate: Double = 48000

    var packs: [SoundPack] {
        if let p = packsBox.get() { return p }
        let found = Self.discoverPacks()
        packsBox.set(found)
        return found
    }
    var status: EngineStatus { statusBox.get() }
    /// Output and spatial state as last built. Thread-safe.
    var route: KeySoundRoute {
        var r = routeBox.get()
        r.output = OutputRoute.shared.info   // always show the live device, even before a rebuild lands
        return r
    }

    private init() {
        let st = sharedStats
        rt = RT(stats: st)
        laneRT = (0..<SpatialGeometry.laneCount).map { _ in RT(stats: st) }
        SpatialSettings.shared.onChange = { [weak self] in self?.scheduleRebuild() }
    }

    var lastLatencyMs: Double { max(0, Double(bitPattern: sharedStats.latencyBits.load(ordering: .relaxed)) * 1000) }
    /// Delay between event capture and the render callback that picked it up (excludes output buffer).
    var lastCallbackDelayMs: Double { max(0, Double(bitPattern: sharedStats.delayBits.load(ordering: .relaxed)) * 1000) }
    var outputBufferFrames: Int { bufFrames }
    var renderedEvents: Int { Int(truncatingIfNeeded: sharedStats.events.load(ordering: .relaxed)) }

    private static func discoverPacks() -> [SoundPack] {
        let fm = FileManager.default
        let dir = soundsDirectory
        let dirs = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
            fm.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent("press").path)
        }
        var out: [SoundPack] = []
        for m in meta where dirs.contains(m.id) { out.append(SoundPack(id: m.id, name: m.name, character: m.character)) }
        for d in dirs.sorted() where !meta.contains(where: { $0.id == d }) {
            out.append(SoundPack(id: d, name: d.capitalized, character: "Custom"))
        }
        return out
    }

    // MARK: Lifecycle

    /// Starts the always-on output stream and subscribes to KeyBus (plays directly on the tap thread).
    func start() {
        ctl.async { [self] in
            if busToken == nil {
                busToken = KeyBus.shared.subscribe { [unowned self] e in self.handle(e, force: false) }
            }
            if routeSub == nil {
                routeSub = OutputRoute.shared.subscribe { [weak self] new in self?.routeChanged(new) }
            }
            if powerObs == nil {
                powerObs = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: nil) { [weak self] _ in
                    self?.ctl.async { self?.powerChangedLocked() }
                }
            }
            lastKeyBits.store(hostNow().bitPattern, ordering: .releasing)
            startEngineLocked()
        }
    }

    /// Non-blocking: teardown runs on the control queue.
    func stop() { ctl.async { [self] in stopLocked() } }

    /// Quit path: waits for the teardown.
    func shutdown() { ctl.sync { stopLocked() } }

    private func stopLocked() {
        if let t = busToken { KeyBus.shared.unsubscribe(t); busToken = nil }
        if let r = routeSub { OutputRoute.shared.unsubscribe(r); routeSub = nil }
        if let o = powerObs { NotificationCenter.default.removeObserver(o); powerObs = nil }
        idleTimer?.cancel(); idleTimer = nil
        idleStopped.store(false, ordering: .releasing)
        tearDownLocked()
        statusBox.set(.stopped)
    }

    // MARK: Battery saver idle stop (ctl queue)

    /// On AC the engine stays up for the lowest first-key latency. In saver mode it stops after a minute
    /// without keys and restarts on the next key.
    private func powerChangedLocked() {
        guard busToken != nil else { return }
        if PowerState.shared.saver {
            if running { _ = configureBuffer(defaultOutputDevice()); armIdleTimerLocked() }
        } else {
            idleTimer?.cancel(); idleTimer = nil
            if idleStopped.load(ordering: .acquiring) { startEngineLocked() }
            else if running { _ = configureBuffer(defaultOutputDevice()) }
        }
    }

    private func armIdleTimerLocked() {
        guard idleTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: ctl)
        t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self, self.running, PowerState.shared.saver else { return }
            let last = Double(bitPattern: self.lastKeyBits.load(ordering: .acquiring))
            if hostNow() - last > Self.idleStopAfter {
                Log.write("[keysound] idle on saver: stopping engine")
                self.tearDownLocked()
                self.idleStopped.store(true, ordering: .releasing)
                self.idleTimer?.cancel(); self.idleTimer = nil
            }
        }
        t.resume()
        idleTimer = t
    }

    /// Thread-safe; switching pack loads it off the realtime path.
    func update(_ c: SoundConfig) {
        setCfg(CfgPOD(enabled: c.enabled, volume: max(0, min(1, c.volume)),
                      spatial: max(0, min(1, c.spatial)), pitchVar: max(0, min(1, c.pitchVariation)),
                      release: c.releaseSounds, modifiers: c.modifierSounds))
        let spread = cfgNow.spatial
        ctl.async { [self] in
            if spread != lastSpread { lastSpread = spread; chain?.setSpread(spread) }
        }
        let old = packID.get()
        packID.set(c.packID)
        if old != c.packID || (running && currentPack?.id != c.packID) {
            ctl.async { [self] in loadPackLocked(c.packID, rate: outRate) }
        }
    }

    /// Play a key as if pressed (UI preview / onboarding). Works without Input Monitoring.
    func preview(keyCode: UInt16) {
        ctl.async { [self] in
            if !running { startEngineLocked() }
            let p = KeyLayout.position(for: keyCode)
            let down = KeyEvent(keyCode: keyCode, down: true, isRepeat: false, time: hostNow(), kind: p.kind,
                                row: p.row, x: p.x, y: p.y)
            handle(down, force: true)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.09) { [self] in
                var up = down; up.down = false; up.time = hostNow()
                handle(up, force: true)
            }
        }
    }

    // MARK: Engine build & system volume compensation (ctl queue)

    /// Boost applied after the soft clip. The soft clip keeps peaks under ~0.9, so +12 dB leaves at most ~3.6
    /// before the system volume stage (which is below 0.25 whenever the boost is at its cap). Devices that
    /// clamp floats before applying volume would clip only the loudest clicks; a larger boost would clip
    /// ordinary ones. Below 25% system volume the clicks get quieter instead of louder.
    static let maxSystemCompDB: Float = 12
    static let maxSystemCompGain: Float = powf(10, 12.0 / 20.0)

    private var systemCompensation: Float {
        get { Float(bitPattern: sysGainBits.load(ordering: .acquiring)) }
        set {
            sysGainBits.store(newValue.bitPattern, ordering: .releasing)
            let bits = newValue.bitPattern
            rt.postGain.store(bits, ordering: .releasing)
            for l in laneRT { l.postGain.store(bits, ordering: .releasing) }
        }
    }

    /// Compensates key-sound gain for macOS output `volume` (0...1).
    /// Silent (0) when muted or volume == 0; otherwise 1/volume capped at +30 dB.
    static func volumeCompensation(volume: Float, muted: Bool) -> Float {
        if muted || !volume.isFinite || volume <= 0 { return 0 }
        return min(maxSystemCompGain, 1 / volume)
    }

    static func readSystemVolume(device dev: AudioObjectID) -> (volume: Float, muted: Bool) {
        guard dev != 0 else { return (1, false) }
        let muted: Bool = {
            if let m = outProp(dev, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, UInt32(0)) {
                return m != 0
            }
            var chans: [UInt32] = []
            for ch: UInt32 in [1, 2] {
                if let m = outProp(dev, kAudioDevicePropertyMute, ch, UInt32(0)) { chans.append(m) }
            }
            return !chans.isEmpty && chans.allSatisfy { $0 != 0 }
        }()
        let volume: Float = {
            if let v = outProp(dev, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain, Float32(0)) {
                return max(0, min(1, v))
            }
            var chans: [Float] = []
            for ch: UInt32 in [1, 2] {
                if let v = outProp(dev, kAudioDevicePropertyVolumeScalar, ch, Float32(0)) {
                    chans.append(max(0, min(1, v)))
                }
            }
            guard !chans.isEmpty else { return 1 }
            return chans.reduce(0, +) / Float(chans.count)
        }()
        return (volume, muted)
    }

    private func refreshSystemVolumeLocked(_ dev: AudioObjectID) {
        let s = Self.readSystemVolume(device: dev)
        systemCompensation = Self.volumeCompensation(volume: s.volume, muted: s.muted)
    }

    private func removeVolumeListenerLocked() {
        guard volDevice != 0, let vl = volListener else { return }
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementWildcard)
            AudioObjectRemovePropertyListenerBlock(volDevice, &addr, ctl, vl)
        }
        volDevice = 0
        volListener = nil
    }

    private func attachVolumeListenerLocked(_ dev: AudioObjectID) {
        removeVolumeListenerLocked()
        refreshSystemVolumeLocked(dev)
        guard dev != 0 else { return }
        let vl: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshSystemVolumeLocked(dev)
        }
        for sel in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementWildcard)
            AudioObjectAddPropertyListenerBlock(dev, &addr, ctl, vl)
        }
        volDevice = dev
        volListener = vl
    }

    private func tearDownLocked() {
        running = false
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        removeVolumeListenerLocked()
        if let l = devListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, ctl, l)
            devListener = nil
        }
        if let e = engine { e.stop(); engine = nil }
        chain = nil
        retired.removeAll()   // renderer stopped: nothing can still read a retired pack
    }

    private func defaultOutputDevice() -> AudioObjectID {
        devProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
    }

    /// Smallest allowed IO buffer >= 64 frames. Returns achieved size.
    private func configureBuffer(_ dev: AudioObjectID) -> Int {
        guard dev != 0 else { return 0 }
        var target: UInt32 = PowerState.shared.saver ? 512 : 128
        if let r = devProp(dev, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal,
                           AudioValueRange()) {
            let want = PowerState.shared.saver ? 512 : max(64, r.mMinimum)
            target = UInt32(min(max(want, r.mMinimum), max(64, r.mMaximum)))
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &target)
        return Int(devProp(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                           UInt32(0)) ?? 0)
    }

    private func startEngineLocked() {
        if running { return }
        idleStopped.store(false, ordering: .releasing)
        statusBox.set(.starting)
        tearDownLocked()
        rt.resetForRestart()
        for l in laneRT { l.resetForRestart() }
        mode.store(0, ordering: .releasing)
        let eng = AVAudioEngine()
        var rate = eng.outputNode.outputFormat(forBus: 0).sampleRate
        if rate < 8000 { rate = 48000 }
        outRate = rate
        if currentPack == nil || currentPack?.rate != rate || currentPack?.id != packID.get() {
            loadPackLocked(packID.get(), rate: rate)
        }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            statusBox.set(.failed("Audio format")); return
        }
        // Route + spatial decision. Bluetooth stays plain unless opted in; call mode is always plain.
        let out = OutputRoute.shared.info
        let st = SpatialSettings.shared.stored
        var route = KeySoundRoute(output: out)
        var useSpatial = false
        if out.callMode {
            route.note = "Headphones are in call mode; using plain stereo."
        } else if SpatialSettings.wantsSpatial(kind: out.kind, st) {
            let ms = SpatialChain.addedLatencyMs(rate: rate, kind: out.kind)
            route.addedLatencyMs = ms
            if let ms, ms <= 3.0 { useSpatial = true }
            else {
                route.note = ms == nil ? "Spatial rendering unavailable; using plain stereo."
                                       : String(format: "Spatial rendering adds %.1f ms; using plain stereo.", ms ?? 0)
                Log.write("[keysound] spatial fallback: \(route.note ?? "")")
            }
        } else if st.enabled && out.kind == .bluetooth {
            route.note = "Bluetooth already adds delay; using plain stereo."
        }
        let tuned = st.speakerTuning && out.kind == .builtInSpeakers
        rt.configureTuning(rate: rate, enabled: tuned)
        for l in laneRT { l.configureTuning(rate: rate, enabled: tuned) }
        builtKind = out.kind; builtCall = out.callMode
        route.spatial = useSpatial
        routeBox.set(route)
        Log.write("[keysound] output \(out.name) kind=\(out.kind.rawValue) rate=\(Int(rate)) path=\(useSpatial ? "spatial" : "plain") tuned=\(tuned)")

        if useSpatial {
            let lanes = laneRT
            let ch = SpatialChain(engine: eng, rate: rate, kind: out.kind, spread: cfgNow.spatial) { lane, frames, buf in
                lanes[lane].renderMono(frames: frames, hostTime: 0, buf: buf)
            }
            chain = ch
            laneGain = SpatialChain.trim(for: out.kind)
            lastSpread = cfgNow.spatial
            mode.store(1, ordering: .releasing)
        } else {
            let core = rt
            let node = AVAudioSourceNode(format: fmt) { isSilence, ts, frames, abl in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard list.count >= 2,
                      let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let active = core.render(frames: Int(frames), hostTime: ts.pointee.mHostTime, left: l, right: r)
                isSilence.pointee = ObjCBool(!active)
                return noErr
            }
            eng.attach(node)
            eng.connect(node, to: eng.mainMixerNode, format: fmt)
            eng.mainMixerNode.outputVolume = 1
        }
        let dev = defaultOutputDevice()
        _ = configureBuffer(dev)
        attachVolumeListenerLocked(dev)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: eng, queue: nil) { [weak self] _ in
            self?.scheduleRebuild()
        }
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshSystemVolumeLocked(self.defaultOutputDevice())
            self.scheduleRebuild()
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, ctl, l)
        devListener = l
        do { try eng.start() } catch {
            mode.store(0, ordering: .releasing)
            statusBox.set(.failed("Audio start: \(error.localizedDescription)"))
            if !startRetryPending {   // one pending retry at a time
                startRetryPending = true
                ctl.asyncAfter(deadline: .now() + 1) { [self] in   // keep retrying while subscribed
                    startRetryPending = false
                    guard busToken != nil, !running else { return }
                    startEngineLocked()
                }
            }
            return
        }
        bufFrames = configureBuffer(dev)   // re-assert after start (engine may have touched it)
        engine = eng
        running = true
        statusBox.set(.running)
        if PowerState.shared.saver { armIdleTimerLocked() }
        SystemAudioTap.shared.recheckExclusion()
    }

    private func routeChanged(_ new: OutputRouteInfo) {
        ctl.async { [self] in
            guard running || busToken != nil else { return }
            if new.kind != builtKind || new.callMode != builtCall || (new.sampleRate > 0 && new.sampleRate != outRate) {
                scheduleRebuild()
            }
        }
    }

    private func scheduleRebuild() {
        ctl.async { [self] in
            if rebuildPending { return }
            rebuildPending = true
            ctl.asyncAfter(deadline: .now() + 0.15) { [self] in
                rebuildPending = false
                guard busToken != nil || running, !idleStopped.load(ordering: .acquiring) else { return }
                running = false
                startEngineLocked()
            }
        }
    }

    // MARK: Pack loading (ctl queue)

    private func packDir(_ id: String) -> URL { Self.soundsDirectory.appendingPathComponent(id) }

    private func loadPackLocked(_ id: String, rate: Double) {
        guard let pk = Self.loadPack(id: id, dir: packDir(id), rate: rate) else {
            Log.write("KeySound: pack \(id) failed to load")
            // A pack decoded for another sample rate would play at the wrong pitch: go silent instead.
            if let old = currentPack, old.rate != rate {
                packBits.store(0, ordering: .releasing)
                retired.append((old, hostNow()))
                currentPack = nil
            }
            return
        }
        if let old = currentPack { retired.append((old, hostNow())) }
        currentPack = pk
        packBits.store(Int(bitPattern: Unmanaged.passUnretained(pk).toOpaque()), ordering: .releasing)
        pruneRetiredLocked()
        schedulePruneLocked()
    }

    private func pruneRetiredLocked() {
        let now = hostNow()
        retired.removeAll { now - $0.1 > 3 }
    }

    /// Retired packs outlive the longest voice by 3 s; free them shortly after that even if no pack loads again.
    private func schedulePruneLocked() {
        guard !retired.isEmpty, !prunePending else { return }
        prunePending = true
        ctl.asyncAfter(deadline: .now() + 3.1) { [self] in
            prunePending = false
            pruneRetiredLocked()
            schedulePruneLocked()
        }
    }

    /// Decodes all 14 samples, trims MP3 lead-in silence, fades tails, packs into one slab.
    fileprivate static func loadPack(id: String, dir: URL, rate: Double) -> PackData? {
        var samples: [[Float]] = []
        var lead: [Int] = []
        for (i, nm) in (PackData.names.map { "press/\($0)" } + PackData.relNames.map { "release/\($0)" }).enumerated() {
            let url = dir.appendingPathComponent(nm + ".mp3")
            var s = decode(url, rate: rate) ?? []
            var l = 0
            if let first = s.firstIndex(where: { abs($0) > 0.001 }) {   // -60 dBFS
                l = max(0, first - 1)
                s.removeFirst(l)
            }
            let maxLen = Int(rate * 0.5)
            if s.count > maxLen { s.removeLast(s.count - maxLen) }
            let fade = min(s.count, max(1, Int(rate * 0.002)))
            if fade > 0 && s.count > 0 {
                for k in 0..<fade { s[s.count - fade + k] *= Float(fade - 1 - k) / Float(fade) }
            }
            if i < 9 && s.isEmpty && i > 0 { s = samples[(i <= 4 || i == 8) ? 0 : 4] }  // missing press -> generic
            samples.append(s); lead.append(l)
        }
        // fall back for missing release samples
        for i in 9..<14 where samples[i].isEmpty { samples[i] = samples[9] }
        guard samples.contains(where: { !$0.isEmpty }) else { return nil }
        var peak: Float = 0
        for s in samples { for v in s { peak = max(peak, abs(v)) } }
        let norm: Float = peak > 0.0001 ? min(6, max(0.5, 0.8 / peak)) : 1
        let total = samples.reduce(0) { $0 + $1.count + 2 }
        let slab = UnsafeMutablePointer<Float>.allocate(capacity: max(1, total))
        slab.initialize(repeating: 0, count: max(1, total))
        var off: [Int] = [], len: [Int32] = [], pos = 0
        for s in samples {
            off.append(pos); len.append(Int32(s.count))
            for (k, v) in s.enumerated() { slab[pos + k] = v * norm }
            pos += s.count + 2
        }
        return PackData(id: id, rate: rate, slab: slab, count: total, off: off, len: len, lead: lead, normGain: norm)
    }

    private static func decode(_ url: URL, rate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = file.processingFormat
        guard file.length > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: inBuf)) != nil,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * rate / inFmt.sampleRate) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let st = conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard st != .error, let ch = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    // MARK: Event admission (any producer thread)

    @inline(__always) private func rand() -> Float {   // uniform [0,1), caller holds spin
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    /// Equal-power pan from normalised key x (0...1) with spatial 0...1: p = 0.55·spatial·(2x−1).
    static func panGains(x: Float, spatial: Float) -> (l: Float, r: Float) {
        let p = 0.55 * spatial * max(-1, min(1, 2 * x - 1))
        let th = (p + 1) * Float.pi / 4
        return (min(1, Float(2).squareRoot() * cosf(th)), min(1, Float(2).squareRoot() * sinf(th)))
    }

    /// Effective stereo pan (-1...1) the plain path applies for a key at normalised `x`, with the per-key clamps.
    static func effectivePan(keyCode: UInt16, x: Float, spatial: Float) -> Float {
        var ex = x
        switch keyCode {
        case 49: ex = 0.5                       // space
        case 36: ex = max(ex, 14.0 / 15.0)      // return
        case 51: ex = max(ex, 14.0 / 15.0)      // backspace
        case 53: ex = min(ex, 1.0 / 15.0)       // escape
        default: break
        }
        return 0.55 * spatial * max(-1, min(1, 2 * ex - 1))
    }

    fileprivate func handle(_ e: KeyEvent, force: Bool) {
        let c = cfgNow
        guard force || c.enabled else { return }
        if e.isRepeat { return }
        lastKeyBits.store(hostNow().bitPattern, ordering: .releasing)
        if idleStopped.load(ordering: .acquiring) {
            idleStopped.store(false, ordering: .releasing)
            ctl.async { [self] in if !running && busToken != nil { startEngineLocked() } }
            return
        }
        let comp = systemCompensation
        guard comp > 0 else { return }
        switch e.kind {
        case .fn: return
        case .capsLock where !e.down: return
        case .modifier where !c.modifiers: return
        default: break
        }
        if !e.down && !c.release { return }
        let bits = packBits.load(ordering: .acquiring)
        guard bits != 0,
              let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let pk = Unmanaged<PackData>.fromOpaque(raw).takeUnretainedValue()

        // sample selection
        var idx: Int
        var gain: Float = 1
        var st: Float = 0
        var x = e.x
        switch e.kind {
        case .space: idx = e.down ? 5 : 10; st = -0.5; x = 0.5
        case .enter: idx = e.down ? 6 : 11; x = max(x, 14.0 / 15.0)
        case .backspace: idx = e.down ? 7 : 12; gain = 0.95; x = max(x, 14.0 / 15.0)
        case .escape: idx = e.down ? 8 : 13; x = min(x, 1.0 / 15.0)
        case .modifier:
            let row = max(0, min(5, e.row))
            idx = e.down ? (row <= 1 ? 0 : row - 1) : 9   // shift (row 4) -> R3, bottom row -> R4
            gain = 0.8; st = -1
        default:
            let row = max(0, min(5, e.row))
            let r = row <= 1 ? 0 : row - 1   // fn+number→R0, tab→R1, caps→R2, shift→R3, bottom→R4
            idx = e.down ? r : 9
        }
        let len = pk.len[idx]
        if len < 2 { return }

        while spin.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged == false {}
        // pitch: jitter + row tilt, never identical to previous
        var jit = (rand() * 2 - 1) * 0.6 * c.pitchVar
        if !e.down { jit = (rand() * 2 - 1) * 0.15 }
        var pitch = st + jit - 0.05 * (Float(e.row) - 2.5)
        if abs(pitch - lastPitchSt) < 0.02 { pitch += 0.05 + 0.05 * rand() }
        lastPitchSt = pitch
        // gain: ±1.2 dB, plus 0.9–1.0 on quick repeats of the same key
        let db = (rand() * 2 - 1) * 1.2
        gain *= powf(10, db / 20)
        if e.down {
            if e.keyCode == lastDownCode && e.time - lastDownTime < 0.08 { gain *= 0.9 + 0.1 * rand() }
            lastDownCode = e.keyCode; lastDownTime = e.time
        } else { gain *= 0.55 }
        let g = gain * c.volume
        if mode.load(ordering: .acquiring) == 1 {
            let lane = SpatialGeometry.lane(forX: x, isSpace: e.kind == .space)
            laneRT[lane].push(RTEvent(ptr: UnsafePointer(pk.slab + pk.off[idx]), len: len, rate: powf(2, pitch / 12),
                                      gL: g * laneGain, gR: 0, time: e.time))
        } else {
            let pan = Self.panGains(x: x, spatial: c.spatial)
            rt.push(RTEvent(ptr: UnsafePointer(pk.slab + pk.off[idx]), len: len, rate: powf(2, pitch / 12),
                            gL: g * pan.l, gR: g * pan.r, time: e.time))
        }
        spin.store(false, ordering: .releasing)
    }

    // MARK: Diagnostics (harness / UI)

    struct PackReport { let id: String; let loadMs: Double; let leadTrimmed: [Int]; let bytes: Int; let norm: Float }

    /// Decodes a pack at `rate` without installing it. For measurement only.
    func debugLoad(_ id: String, rate: Double) -> PackReport? {
        let t0 = hostNow()
        guard let p = Self.loadPack(id: id, dir: packDir(id), rate: rate) else { return nil }
        return PackReport(id: id, loadMs: (hostNow() - t0) * 1000, leadTrimmed: p.lead, bytes: p.bytes, norm: p.normGain)
    }

    /// Offline render of the real key path (producer -> RT -> chain) with no audio device. `keys` are
    /// (keyCode, ms from start) key-downs. Must not be used while the live engine runs.
    func debugRenderOffline(spatial: Bool, kind: OutputKind, rate: Double, keys: [(code: UInt16, atMs: Double)],
                            totalMs: Double, tuned: Bool, spread: Float = 0.8, volume: Float? = nil,
                            systemVolume: Float? = nil, systemMuted: Bool = false) -> (l: [Float], r: [Float])? {
        ctl.sync {
            let oldCfg = cfgNow
            let oldComp = systemCompensation
            if let volume { var c = oldCfg; c.volume = volume; setCfg(c) }
            systemCompensation = (systemVolume != nil || systemMuted)
                ? Self.volumeCompensation(volume: systemVolume ?? 1, muted: systemMuted)
                : 1
            defer { var c = cfgNow; c.volume = oldCfg.volume; setCfg(c); systemCompensation = oldComp }
            loadPackLocked(packID.get(), rate: rate)
            rt.resetForRestart(); for l in laneRT { l.resetForRestart() }
            rt.configureTuning(rate: rate, enabled: tuned)
            for l in laneRT { l.configureTuning(rate: rate, enabled: tuned) }
            var cs = cfgNow; cs.spatial = spread; setCfg(cs)
            let lanes = laneRT, core = rt
            var ch: SpatialChain?
            var plain: AVAudioEngine?
            if spatial {
                ch = SpatialChain.makeOffline(rate: rate, kind: kind, spread: spread, maxFrames: 64) { lane, frames, buf in
                    lanes[lane].renderMono(frames: frames, hostTime: 0, buf: buf)
                }
                guard ch != nil else { return nil }
                laneGain = SpatialChain.trim(for: kind)
                mode.store(1, ordering: .releasing)
            } else {
                mode.store(0, ordering: .releasing)
                let eng = AVAudioEngine()
                guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
                      (try? eng.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 64)) != nil else { return nil }
                let node = AVAudioSourceNode(format: fmt) { silence, _, frames, abl in
                    let list = UnsafeMutableAudioBufferListPointer(abl)
                    guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                          let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                    silence.pointee = ObjCBool(!core.render(frames: Int(frames), hostTime: 0, left: l, right: r))
                    return noErr
                }
                eng.attach(node); eng.connect(node, to: eng.mainMixerNode, format: fmt)
                eng.prepare()
                guard (try? eng.start()) != nil else { return nil }
                plain = eng
            }
            defer { mode.store(0, ordering: .releasing); plain?.stop(); ch?.engine.stop() }
            let total = Int(totalMs / 1000 * rate), step = 64
            let pending = keys.sorted { $0.atMs < $1.atMs }
            var next = 0
            var L: [Float] = [], R: [Float] = []
            guard let buf = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!,
                                             frameCapacity: AVAudioFrameCount(step)) else { return nil }
            var done = 0
            let eng = ch?.engine ?? plain!
            while done < total {
                let nowMs = Double(done) / rate * 1000
                while next < pending.count && pending[next].atMs <= nowMs {
                    let p = KeyLayout.position(for: pending[next].code)
                    handle(KeyEvent(keyCode: pending[next].code, down: true, isRepeat: false, time: hostNow(), kind: p.kind,
                                    row: p.row, x: p.x, y: p.y), force: true)
                    next += 1
                }
                guard (try? eng.renderOffline(AVAudioFrameCount(step), to: buf)) != nil, let d = buf.floatChannelData else { break }
                L += UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength))
                R += UnsafeBufferPointer(start: d[1], count: Int(buf.frameLength))
                done += step
            }
            return (L, R)
        }
    }

    var debugDeviceLatency: (deviceFrames: UInt32, safetyFrames: UInt32, streamFrames: UInt32, rate: Double) {
        let dev = defaultOutputDevice()
        let lat = devProp(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, UInt32(0)) ?? 0
        let saf = devProp(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, UInt32(0)) ?? 0
        var stream: UInt32 = 0
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size >= 4 {
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ids) == noErr, let s = ids.first {
                stream = devProp(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
            }
        }
        return (lat, saf, stream, outRate)
    }
}
