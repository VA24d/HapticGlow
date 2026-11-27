// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow — default output route detection, spatial key-sound settings and the spatial render chain.
//
// OutputRoute watches the default output device (kind, name, nominal rate) and publishes a snapshot.
// SpatialSettings holds the "Spatial key sounds" options (own UserDefaults key).
// SpatialChain builds the AVAudioEngine graph used for positioned key clicks:
//   mono lane sources -> AVAudioEnvironmentNode -> peak limiter -> main mixer.
// The same builder runs live and in manual (offline) rendering mode so it can be measured without audio.
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Observation

// MARK: - Route model

enum OutputKind: String, Sendable {
    case builtInSpeakers, wiredHeadphones, bluetooth, airPlay, display, other, none

    var isHeadphoneLike: Bool { self == .wiredHeadphones || self == .bluetooth }
}

struct OutputRouteInfo: Sendable, Equatable {
    var deviceID: AudioObjectID = 0
    var name: String = ""
    var kind: OutputKind = .none
    var sampleRate: Double = 0
    var transport: UInt32 = 0
    /// Bluetooth output whose nominal rate fell to the HFP range (8/16 kHz): the headset mic is open somewhere.
    var callMode: Bool = false

    var label: String {
        switch kind {
        case .builtInSpeakers: return name.isEmpty ? "MacBook Speakers" : name
        default: return name.isEmpty ? "No output" : name
        }
    }
}

// MARK: - CoreAudio helpers

private func prop<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                      _ zero: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

private func cfString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &s) == noErr, let s else { return "" }
    return s.takeRetainedValue() as String
}

private func streamCount(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioObjectID>.size
}

// MARK: - OutputRoute

final class OutputRoute: @unchecked Sendable {
    static let shared = OutputRoute()

    private let queue = DispatchQueue(label: "HapticGlow.OutputRoute", qos: .utility)
    private let box = Locked(OutputRouteInfo())
    private let listeners = Locked<[(id: Int, fn: (OutputRouteInfo) -> Void)]>([])
    private var nextID = 1
    private var started = false
    private var sysBlock: AudioObjectPropertyListenerBlock?
    private var devBlock: AudioObjectPropertyListenerBlock?
    private var watched: AudioObjectID = 0
    private var lastCallMode = false

    /// Thread-safe snapshot. Starts watching on first use.
    var info: OutputRouteInfo { start(); return box.get() }

    /// Called (on a private queue) when device, kind, rate or call-mode state changes.
    @discardableResult
    func subscribe(_ fn: @escaping (OutputRouteInfo) -> Void) -> Int {
        start()
        return listeners.update2 { l in let id = nextID; nextID += 1; l.append((id, fn)); return id }
    }
    func unsubscribe(_ id: Int) { listeners.update { $0.removeAll { $0.id == id } } }

    func start() {
        queue.sync {
            guard !started else { return }
            started = true
            box.set(Self.read())
            let sys = AudioObjectID(kAudioObjectSystemObject)
            let b: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            sysBlock = b
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(sys, &a, queue, b)
            rewatch()
        }
    }

    private func rewatch() {   // queue only
        let cur = box.get().deviceID
        if cur == watched { return }
        let db: AudioObjectPropertyListenerBlock = devBlock ?? { [weak self] _, _ in self?.refresh() }
        devBlock = db
        let sels: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        ]
        for (s, sc) in sels {
            if watched != 0 {
                var a = AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(watched, &a, queue, db)
            }
            if cur != 0 {
                var a = AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(cur, &a, queue, db)
            }
        }
        watched = cur
    }

    private func refresh() {
        let old = box.get()
        let new = Self.read()
        box.set(new)
        rewatch()
        if new.callMode != lastCallMode {
            lastCallMode = new.callMode
            Log.write(new.callMode
                ? "[output] call mode on: \(new.name) dropped to \(Int(new.sampleRate)) Hz (headset mic in use)"
                : "[output] call mode off: \(new.name) at \(Int(new.sampleRate)) Hz")
        }
        guard new != old else { return }
        if new.kind != old.kind || new.deviceID != old.deviceID {
            Log.write("[output] route \(new.name) kind=\(new.kind.rawValue) rate=\(Int(new.sampleRate))")
        }
        for l in listeners.get() { l.fn(new) }
    }

    static func read() -> OutputRouteInfo {
        let dev: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                      kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
        guard dev != 0 else { return OutputRouteInfo() }
        let transport: UInt32 = prop(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        let rate: Double = prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Double(0)) ?? 0
        let name = cfString(dev, kAudioObjectPropertyName)
        let src: UInt32 = prop(dev, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, UInt32(0)) ?? 0
        let kind = classify(transport: transport, dataSource: src, name: name)
        var info = OutputRouteInfo(deviceID: dev, name: name, kind: kind, sampleRate: rate, transport: transport)
        info.callMode = kind == .bluetooth && rate > 0 && rate <= 16000
        return info
    }

    /// Built-in devices expose a data source: 'ispk' (internal speaker) or 'hdpn' (headphone jack).
    static func classify(transport: UInt32, dataSource: UInt32, name: String) -> OutputKind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == fourCC("hdpn") ? .wiredHeadphones : .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return .display
        case kAudioDeviceTransportTypeThunderbolt:
            // Thunderbolt carries docks and audio interfaces too: only a device named like a display counts.
            return isDisplayName(name) ? .display : .other
        case kAudioDeviceTransportTypeUSB:
            // USB DACs and headsets are overwhelmingly headphones in practice; treat as wired headphones.
            let n = name.lowercased()
            return (n.contains("headphone") || n.contains("headset") || n.contains("airpods")) ? .wiredHeadphones : .other
        default:
            return .other
        }
    }

    private static func isDisplayName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("display") || n.contains("monitor") || n.contains("hdmi")
    }

    /// True for audio that travels inside a video signal (DisplayPort, HDMI, Thunderbolt display): monitors and
    /// TVs often buffer it to match their video processing, so the latency macOS reports is usually too low.
    static func isDisplayAudio(transport: UInt32, name: String) -> Bool {
        classify(transport: transport, dataSource: 0, name: name) == .display
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    // MARK: Input switch (call-mode escape hatch)

    /// Built-in microphone: transport built-in with input streams (never matched by name).
    static func builtInInputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for d in ids {
            let t: UInt32 = prop(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
            if t == kAudioDeviceTransportTypeBuiltIn && streamCount(d, kAudioObjectPropertyScopeInput) > 0 { return d }
        }
        return nil
    }

    /// Sets the system default input to the built-in microphone. Returns false if none was found or the set failed.
    @discardableResult
    static func useBuiltInMicrophone() -> Bool {
        guard var dev = builtInInputDevice() else { Log.write("[output] no built-in microphone found"); return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioObjectID>.size), &dev)
        Log.write("[output] default input -> built-in microphone (status \(st))")
        return st == noErr
    }
}

private extension Locked {
    func update2<R>(_ body: (inout Value) -> R) -> R {
        var r: R!
        update { r = body(&$0) }
        return r
    }
}

// MARK: - Settings

/// "Spatial key sounds" options. Persisted under its own UserDefaults key.
@Observable
final class SpatialSettings: @unchecked Sendable {
    static let shared = SpatialSettings()
    private static let key = "hapticglow.keySpatial.v1"

    struct Stored: Codable, Equatable {
        var enabled = true            // spatial rendering on speakers and wired headphones
        var onBluetooth = false       // opt-in: also spatialise on Bluetooth (adds latency risk)
        var speakerTuning = true      // psychoacoustic bass + low shelf on built-in speakers
    }

    var enabled: Bool { didSet { let v = enabled; changed { $0.enabled = v } } }
    var onBluetooth: Bool { didSet { let v = onBluetooth; changed { $0.onBluetooth = v } } }
    var speakerTuning: Bool { didSet { let v = speakerTuning; changed { $0.speakerTuning = v } } }

    /// Called after any change (engine rebuild hook), main or any thread.
    var onChange: (() -> Void)? {
        get { hookLock.withLock { _onChange } }
        set { hookLock.withLock { _onChange = newValue } }
    }
    @ObservationIgnored private var _onChange: (() -> Void)?
    @ObservationIgnored private let hookLock = UnfairLock()
    /// Lock-protected copy read by background threads; the observable properties above are for the UI.
    @ObservationIgnored private let snapshot: Locked<Stored>

    init() {
        var s = Stored()
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let v = try? JSONDecoder().decode(Stored.self, from: d) { s = v }
        snapshot = Locked(s)
        enabled = s.enabled; onBluetooth = s.onBluetooth; speakerTuning = s.speakerTuning
    }

    var stored: Stored { snapshot.get() }

    private func changed(_ edit: (inout Stored) -> Void) {
        let s = snapshot.update2 { edit(&$0); return $0 }
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.key) }
        onChange?()
    }

    /// Rule: spatial on speakers and wired headphones; Bluetooth stays plain stereo unless opted in.
    static func wantsSpatial(kind: OutputKind, _ s: Stored) -> Bool {
        guard s.enabled else { return false }
        switch kind {
        case .builtInSpeakers, .wiredHeadphones: return true
        case .bluetooth: return s.onBluetooth
        default: return false
        }
    }
}

// MARK: - Spatial chain

enum SpatialGeometry {
    static let laneCount = 10          // 9 columns across the board + 1 front-centre lane for space
    static let spaceLane = 9
    static let columns = 9

    /// Lane for a normalised key x (0...1).
    static func lane(forX x: Float, isSpace: Bool) -> Int {
        if isSpace { return spaceLane }
        return Int((max(0, min(1, x)) * Float(columns - 1)).rounded())
    }

    /// Source position in metres, listener at the origin facing -z. Keyboard sits ~0.5 m ahead, below ear level.
    /// `spread` 0...1 scales the half-angle up to 50 degrees. Back rows sit slightly further away.
    static func position(lane: Int, spread: Float) -> AVAudio3DPoint {
        if lane == spaceLane { return AVAudio3DPoint(x: 0, y: -0.2, z: -0.45) }
        let u = 2 * Float(lane) / Float(columns - 1) - 1
        let az = u * 50 * .pi / 180 * max(0, min(1, spread))
        let d: Float = 0.55
        return AVAudio3DPoint(x: d * sinf(az), y: -0.2, z: -d * cosf(az))
    }
}

final class SpatialChain {
    /// Renders mono lane `lane` into `buf` (`frames` samples). Returns false when silent.
    typealias LaneRender = (_ lane: Int, _ frames: Int, _ buf: UnsafeMutablePointer<Float>) -> Bool

    /// Output peak ceiling after the limiter, dBFS.
    static let ceilingDB: Float = -1.2
    /// Source rendering algorithm on built-in speakers. `.auto` was measured to place keys non-monotonically
    /// (steps, and frequency dependent), so the smooth sound-field decode is used instead.
    nonisolated(unsafe) static var speakerAlgorithm: AVAudio3DMixingRenderingAlgorithm = .soundField

    let engine: AVAudioEngine
    let environment = AVAudioEnvironmentNode()
    let limiter: AVAudioUnitEffect
    private(set) var lanes: [AVAudioSourceNode] = []
    let kind: OutputKind
    let rate: Double

    init(engine: AVAudioEngine, rate: Double, kind: OutputKind, spread: Float, render: @escaping LaneRender) {
        self.engine = engine; self.kind = kind; self.rate = rate
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_PeakLimiter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        limiter = AVAudioUnitEffect(audioComponentDescription: desc)

        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

        engine.attach(environment)
        engine.attach(limiter)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        environment.reverbParameters.enable = false
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.outputType = (kind == .builtInSpeakers) ? .builtInSpeakers : .headphones

        let algo: AVAudio3DMixingRenderingAlgorithm = (kind == .builtInSpeakers) ? Self.speakerAlgorithm : .HRTFHQ
        for i in 0..<SpatialGeometry.laneCount {
            let n = AVAudioSourceNode(format: mono) { isSilence, _, frames, abl in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard let p = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let active = render(i, Int(frames), p)
                isSilence.pointee = ObjCBool(!active)
                return noErr
            }
            engine.attach(n)
            engine.connect(n, to: environment, format: mono)
            n.renderingAlgorithm = algo
            n.sourceMode = .spatializeIfMono
            n.reverbBlend = 0
            n.volume = 1
            n.position = SpatialGeometry.position(lane: i, spread: spread)
            lanes.append(n)
        }
        engine.connect(environment, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        // Limiter ceiling is 0 dBFS; trim after it so peaks stay at or below `ceilingDB`.
        engine.mainMixerNode.outputVolume = powf(10, Self.ceilingDB / 20)
        let au = limiter.audioUnit
        AudioUnitSetParameter(au, AudioUnitParameterID(kLimiterParam_AttackTime), kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(au, AudioUnitParameterID(kLimiterParam_DecayTime), kAudioUnitScope_Global, 0, 0.02, 0)
        AudioUnitSetParameter(au, AudioUnitParameterID(kLimiterParam_PreGain), kAudioUnitScope_Global, 0, 0, 0)
    }

    func setSpread(_ spread: Float) {
        for (i, n) in lanes.enumerated() { n.position = SpatialGeometry.position(lane: i, spread: spread) }
    }

    /// Per-lane gain applied by the producer so a centred click through the environment node lands near the
    /// level of the plain stereo path.
    static let laneTrim: Float = 1.25
    /// The speaker decode renders ~4 dB quieter than the plain path (measured), so it gets extra trim.
    static func trim(for kind: OutputKind) -> Float { kind == .builtInSpeakers ? laneTrim * 1.6 : laneTrim }

    // MARK: Offline rendering (tests and latency probe; never touches the output device)

    /// Builds the chain on `engine` in manual offline rendering mode (stereo, `maxFrames` per call) and starts it.
    static func makeOffline(rate: Double, kind: OutputKind, spread: Float, maxFrames: AVAudioFrameCount = 512,
                            render: @escaping LaneRender) -> SpatialChain? {
        let eng = AVAudioEngine()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return nil }
        do { try eng.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames) }
        catch { return nil }
        let ch = SpatialChain(engine: eng, rate: rate, kind: kind, spread: spread, render: render)
        eng.prepare()
        do { try eng.start() } catch { return nil }
        return ch
    }

    /// Renders `frames` frames offline. Returns interleaved-free left/right arrays.
    func renderOffline(frames: Int) -> (l: [Float], r: [Float]) {
        let step = Int(engine.manualRenderingMaximumFrameCount)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(step)) else { return ([], []) }
        var l: [Float] = [], r: [Float] = []
        var done = 0
        while done < frames {
            let n = min(step, frames - done)
            guard (try? engine.renderOffline(AVAudioFrameCount(n), to: buf)) != nil,
                  let d = buf.floatChannelData else { break }
            l += UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength))
            r += UnsafeBufferPointer(start: d[1], count: Int(buf.frameLength))
            done += n
        }
        return (l, r)
    }

    private static let latencyCache = Locked<[String: Double]>([:])

    /// Delay from a centre-lane impulse to the first audible output sample, in ms, measured offline
    /// (the plain path has none). Cached per kind and rate. Nil if the chain could not be built.
    static func addedLatencyMs(rate: Double, kind: OutputKind) -> Double? {
        let key = "\(kind.rawValue)@\(Int(rate))"
        if let v = latencyCache.get()[key] { return v }
        // 5 ms burst of 2 kHz starting abruptly at frame 0 (a single-sample click is filtered to nothing by some
        // algorithms, so it cannot be used for onset timing).
        let sent = Locked(0)
        let burst = Int(rate * 0.005)
        guard let ch = makeOffline(rate: rate, kind: kind, spread: 0.8, maxFrames: 128, render: { lane, frames, buf in
            for n in 0..<frames { buf[n] = 0 }
            guard lane == 4 else { return false }
            let start = sent.get()
            guard start < burst else { return false }
            for n in 0..<frames where start + n < burst { buf[n] = 0.5 * sinf(2 * .pi * 2000 * Float(start + n) / Float(rate)) }
            sent.set(start + frames)
            return true
        }) else { return nil }
        let (l, r) = ch.renderOffline(frames: 4096)
        var peak: Float = 0
        for i in 0..<l.count { peak = max(peak, abs(l[i]), abs(r[i])) }
        guard peak > 1e-6, let first = (0..<l.count).first(where: { max(abs(l[$0]), abs(r[$0])) > 0.1 * peak }) else { return nil }
        let ms = Double(first) / rate * 1000
        latencyCache.update { $0[key] = ms }
        return ms
    }
}
