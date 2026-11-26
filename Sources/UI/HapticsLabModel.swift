// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Haptics Lab: manual low-level primitives. All output goes through TrackpadMotor, whose governor enforces
// the hard limits (Apple's own amplitude table, rate, duty, stall guard). The sliders here only mirror them.
import SwiftUI

enum LabPrimitive: String, CaseIterable, Identifiable {
    case pulse, sine, train, apple
    var id: String { rawValue }
    var title: String {
        switch self { case .pulse: "Pulse"; case .sine: "Sine"; case .train: "Pulse train"; case .apple: "Apple waveform" }
    }
}

/// Apple's own actuation IDs with the names used in the library notes.
struct AppleWaveform: Identifiable, Hashable {
    let id: Int32
    let name: String
    static let all: [AppleWaveform] = [
        .init(id: 1, name: "Light click"), .init(id: 2, name: "Medium click"), .init(id: 3, name: "Light click, alt"),
        .init(id: 4, name: "Medium click, alt"), .init(id: 5, name: "Soft click"), .init(id: 6, name: "Firm click"),
        .init(id: 15, name: "Buzz"), .init(id: 16, name: "Buzz, alt"),
    ]
    var label: String { "\(id)  \(name)" }
}

struct LabPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let primitive: LabPrimitive
    var amplitude: Float = 30
    var width: Float = 6
    var freq: Float = 60
    var duration: Float = 40
    var level: Float = 0.8
    var rate: Float = 40
    var count: Int = 8
    var waveID: Int32 = 6
    var brake = false
}

enum LabPresets {
    /// Round 1 and 2: single Gaussian pulses. Round 3: sustained energy.
    static let round1: [LabPreset] = [
        .init(id: "r1-soft", title: "1 Soft", detail: "amp 10, 10 ms", primitive: .pulse, amplitude: 10, width: 10, level: 1),
        .init(id: "r1-medium", title: "2 Medium", detail: "amp 20, 6 ms", primitive: .pulse, amplitude: 20, width: 6, level: 1),
        .init(id: "r1-strong", title: "3 Strong", detail: "amp 30, 6 ms", primitive: .pulse, amplitude: 30, width: 6, level: 1),
        .init(id: "r1-sharp", title: "4 Sharp", detail: "amp 30, 3 ms", primitive: .pulse, amplitude: 30, width: 3, level: 1),
        .init(id: "r1-round", title: "5 Round", detail: "amp 30, 12 ms", primitive: .pulse, amplitude: 30, width: 12, level: 1),
    ]
    static let round2: [LabPreset] = [
        .init(id: "r2-35", title: "Amp 35", detail: "10 ms", primitive: .pulse, amplitude: 35, width: 10, level: 1),
        .init(id: "r2-48", title: "Amp 48", detail: "10 ms, Apple's max", primitive: .pulse, amplitude: 48, width: 10, level: 1),
        .init(id: "r2-double", title: "Double pulse", detail: "amp 35, 80 Hz", primitive: .train, amplitude: 35, width: 10, level: 1, rate: 80, count: 2),
        .init(id: "r2-pushpull", title: "Push-pull", detail: "+35 then -35", primitive: .pulse, amplitude: 35, width: 10, level: 1, brake: true),
        .init(id: "r2-id6", title: "Apple ID 6", detail: "firm click", primitive: .apple, waveID: 6),
    ]
    static let round3: [LabPreset] = [
        .init(id: "r3-50", title: "Sine 50 Hz", detail: "60 ms, 0.8", primitive: .sine, freq: 50, duration: 60, level: 0.8),
        .init(id: "r3-80", title: "Sine 80 Hz", detail: "60 ms, 0.8", primitive: .sine, freq: 80, duration: 60, level: 0.8),
        .init(id: "r3-150", title: "Sine 150 Hz", detail: "40 ms, 0.6", primitive: .sine, freq: 150, duration: 40, level: 0.6),
        .init(id: "r3-t50", title: "Train 50 Hz", detail: "amp 48, 6 ms", primitive: .train, amplitude: 48, width: 6, level: 1, rate: 50, count: 10),
        .init(id: "r3-t40", title: "Train 40 Hz", detail: "amp 48, 12 ms", primitive: .train, amplitude: 48, width: 12, level: 1, rate: 40, count: 8),
        .init(id: "r3-15", title: "Apple buzz", detail: "ID 15", primitive: .apple, waveID: 15),
    ]
}

/// Plays lab sequences on one background queue, so the UI never blocks on the ~3.7 ms actuator call.
final class LabPlayer: @unchecked Sendable {
    static let shared = LabPlayer()
    private let queue = DispatchQueue(label: "hapticglow.lab", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    /// Cancels a sequence still in flight (e.g. a long pulse train).
    func cancel() { lock.withLock { generation += 1 } }

    func run(preferExternal: Bool, result: @escaping @Sendable (Int32) -> Void, _ body: @escaping @Sendable (TrackpadMotor, () -> Bool) -> Int32) {
        let gen = lock.withLock { generation += 1; return generation }
        queue.async { [self] in
            let motor = TrackpadMotor.shared
            if !motor.isAvailable { motor.open(preferExternal: preferExternal) }
            guard motor.isAvailable else { result(-1); return }
            let alive: () -> Bool = { self.lock.withLock { self.generation == gen } }
            result(body(motor, alive))
        }
    }

    static func sleep(until t: Double) {
        let d = t - CFAbsoluteTimeGetCurrent()
        if d > 0 { Thread.sleep(forTimeInterval: d) }
    }
}

@MainActor @Observable
final class HapticsLabModel {
    static let shared = HapticsLabModel()

    var primitive: LabPrimitive = .pulse { didSet { clampLevel() } }
    var amplitude: Float = 30
    var width: Float = 6
    var freq: Float = 60
    var duration: Float = 40
    var level: Float = 0.8
    var rate: Float = 40
    var count: Float = 8
    var waveID: Int32 = 6
    var brake = false
    var lastRC: Int32?
    var activePreset: String?

    var levelMax: Float { primitive == .sine ? 0.8 : 1 }
    var usesAmplitude: Bool { primitive == .pulse || primitive == .train }
    /// Effective Gaussian strength after the central |amplitude x level| <= 48 cap.
    var effectiveAmplitude: Float { min(48, amplitude * level) }

    private func clampLevel() { level = min(level, levelMax) }

    func apply(_ p: LabPreset) {
        primitive = p.primitive
        amplitude = p.amplitude; width = p.width; freq = p.freq; duration = p.duration
        level = min(p.level, p.primitive == .sine ? 0.8 : 1)
        rate = p.rate; count = Float(p.count); waveID = p.waveID; brake = p.brake
        activePreset = p.id
    }

    func rcText(_ rc: Int32) -> (text: String, ok: Bool) {
        switch rc {
        case 0: return ("Played", true)
        case MotorRC.throttled: return ("Refused by the governor (rate or duty limit)", false)
        case MotorRC.stalled: return ("Haptics stopped by the stall guard. Reset it below.", false)
        case MotorRC.invalid: return ("Invalid value", false)
        case -1: return ("Trackpad unavailable", false)
        default: return ("Actuator returned \(rc)", false)
        }
    }

    func play() {
        let prim = primitive
        let a = amplitude, w = width, f = freq, d = duration, lv = level
        let hz = max(1, rate), n = max(1, Int(count.rounded())), id = waveID, br = brake
        LabPlayer.shared.run(preferExternal: AppModel.shared.haptic.preferExternal,
                             result: { rc in Task { @MainActor in HapticsLabModel.shared.lastRC = rc } }) { m, alive in
            switch prim {
            case .pulse:
                var rc = m.pulse(amplitude: a, widthMS: w, level: lv)
                if br, rc == 0 {
                    LabPlayer.sleep(until: CFAbsoluteTimeGetCurrent() + Double(w) * 0.001)
                    rc = m.pulse(amplitude: -a, widthMS: w, level: lv)
                }
                return rc
            case .sine:
                return m.sine(hz: f, ms: d, level: lv)
            case .train:
                var rc: Int32 = 0
                let t0 = CFAbsoluteTimeGetCurrent()
                for i in 0..<n {
                    guard alive() else { break }
                    LabPlayer.sleep(until: t0 + Double(i) / Double(hz))
                    rc = m.pulse(amplitude: a, widthMS: w, level: lv)
                    if rc != 0 { break }
                    if br {
                        LabPlayer.sleep(until: CFAbsoluteTimeGetCurrent() + Double(w) * 0.001)
                        rc = m.pulse(amplitude: -a, widthMS: w, level: lv)
                        if rc != 0 { break }
                    }
                }
                return rc
            case .apple:
                return m.systemWaveform(id: id)
            }
        }
    }
}
