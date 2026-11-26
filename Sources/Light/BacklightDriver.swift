// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow — keyboard backlight driver (CoreBrightness private framework) + crash-safe state guard.
//
// Ported from MagicKey (MIT, XiaoSong1223): Driver.swift (selector protocol, 8-bit dedupe) and
// StateGuard.swift (snapshot / restore / crash recovery). Extended for HapticGlow:
//  - suspendIdleDimming (the 5 s idle dim is why the light never reached full brightness while
//    music played), dimmed/suppressed diagnostics, write timing stats.
//  - restore order: suspendIdleDimming(false), idleDimTime, autoBrightness, brightness LAST.
//  - SIGINT/SIGTERM handlers restore before the process dies.
// Never applies a gamma curve: level 1.0 writes exactly 1.0 (255/255).
import Foundation
import Darwin
import IOKit

struct BacklightDiagnostics: Sendable {
    var available = false
    var keyboardID: UInt64 = 0
    var writes: UInt64 = 0
    var skipped: UInt64 = 0
    var lastWritten: Float = 0
    var systemLevel: Float = 0        // brightnessForKeyboard:
    var suppressed = false            // isBacklightSuppressedOnKeyboard:
    var dimmed = false                // isBacklightDimmedOnKeyboard:
    var autoBrightness = false        // isAutoBrightnessEnabledForKeyboard:
    var idleDimSuspended = false
    var idleDimTime: Double = 0
    var avgWriteMicros: Double = 0
}

// Private CoreBrightness interface mapped through an @objc protocol with explicit selectors.
// Optional selectors are probed with responds(to:) before use.
@objc private protocol KBClient {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> [NSNumber]
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ kb: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard kb: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func setBrightness(_ b: Float, forKeyboard kb: UInt64) -> Bool
    @objc(setBrightness:fadeSpeed:commit:forKeyboard:)
    func setBrightness(_ b: Float, fadeSpeed: Int32, commit: Bool, forKeyboard kb: UInt64) -> Bool
    @objc(enableAutoBrightness:forKeyboard:) func enableAutoBrightness(_ e: Bool, forKeyboard kb: UInt64) -> Bool
    @objc(isAutoBrightnessEnabledForKeyboard:) func isAutoBrightnessEnabled(forKeyboard kb: UInt64) -> Bool
    @objc(idleDimTimeForKeyboard:) func idleDimTime(forKeyboard kb: UInt64) -> Double
    @objc(setIdleDimTime:forKeyboard:) func setIdleDimTime(_ t: Double, forKeyboard kb: UInt64) -> Bool
    @objc(suspendIdleDimming:forKeyboard:) func suspendIdleDimming(_ s: Bool, forKeyboard kb: UInt64) -> Bool
    @objc(isIdleDimmingSuspendedOnKeyboard:) func isIdleDimmingSuspended(onKeyboard kb: UInt64) -> Bool
    @objc(isBacklightDimmedOnKeyboard:) func isBacklightDimmed(onKeyboard kb: UInt64) -> Bool
    @objc(isBacklightSuppressedOnKeyboard:) func isBacklightSuppressed(onKeyboard kb: UInt64) -> Bool
}

private struct BacklightSnapshot: Codable {
    var brightness: Float
    var autoBrightnessEnabled: Bool
    var idleDimTime: Double
    var capturedAt: Date
    var pid: Int32
}

final class BacklightDriver: @unchecked Sendable {
    static let shared = BacklightDriver()

    private let lock = UnfairLock()
    private let raw: NSObject?
    private let client: KBClient?
    private let kbID: UInt64

    // Measured Apple Silicon backlight timings:
    //  - plain setBrightness:forKeyboard: makes corebrightnessd ramp for ~350 ms, so 120 Hz writes never land.
    //  - setBrightness:fadeSpeed:0 commit:NO applies the duty in ~0.3 ms (lag 2-4 ms at 120/240 writes/s).
    //  - fadeSpeed 0 silently ignores an exact 0.0; "off" therefore goes through the plain call.
    //  - Hardware: PWM period 960 ticks, linear in value, duty 54...336 = ~283 true levels.
    private lazy var useFadeVariant: Bool = responds("setBrightness:fadeSpeed:commit:forKeyboard:")
    private var lastValue: Float = -1
    private var isOff = false

    // Dark-band glide. Duty below 54 ticks cannot be addressed
    // by value (anything > 0 clamps to 54, exact 0 is "off" = duty 6), but a PLAIN setBrightness is a
    // linear corebrightnessd ramp (~107 ticks/s, 19 ms latency) that starts from the live duty and can be
    // redirected mid-flight. The driver therefore runs the band feed-forward: one plain write toward 0 to
    // glide down, one toward the floor to glide up, never one per frame (a rewrite restarts the ramp).
    static let maxDuty = 336.0, floorDuty = 54.0, offDuty = 6.0
    private enum Glide { case lit, down, up }
    private var glide: Glide = .lit
    private var dModel = 54.0            // estimated live duty while gliding
    private var modelT = 0.0
    private var cmdT = 0.0               // when the last plain write was issued
    private var cmdTarget = 54.0         // duty target of the last plain write
    private var lastPlainV: Float = -1
    private var lastDuty = 54.0          // duty of the last lit write
    private var prevD = 0.0, prevDT = 0.0
    private var turnD = 0.0              // running min (down) / max (up) of the requested duty
    private var ewmaWriteMs: Double = 0

    private var taken = false
    private var sealed = false           // set by the signal path: no takeOver after the final restore
    private var keepAwake = false
    private var snapshot: BacklightSnapshot?
    private var lastLevel = -1
    private var writeCount: UInt64 = 0
    private var skipCount: UInt64 = 0
    private var totalWriteSeconds: Double = 0

    private static let snapshotURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HapticGlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backlight-snapshot.json")
    }()

    init() {
        var inst: NSObject?
        var proto: KBClient?
        var id: UInt64 = 0
        if dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
           let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let o = cls.init()
            let required = ["copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:",
                            "setBrightness:forKeyboard:", "enableAutoBrightness:forKeyboard:",
                            "isAutoBrightnessEnabledForKeyboard:", "idleDimTimeForKeyboard:",
                            "setIdleDimTime:forKeyboard:", "suspendIdleDimming:forKeyboard:"]
            if required.allSatisfy({ o.responds(to: NSSelectorFromString($0)) }) {
                let p = unsafeBitCast(o, to: KBClient.self)
                if let b = p.copyKeyboardBacklightIDs().map({ $0.uint64Value }).first(where: { p.isKeyboardBuiltIn($0) }) {
                    inst = o; proto = p; id = b
                }
            }
        }
        raw = inst; client = proto; kbID = id
    }

    var isAvailable: Bool { client != nil }
    var isTakenOver: Bool { lock.withLock { taken } }
    /// The user's brightness captured at takeOver (or current level if not taken over).
    var savedBrightness: Float {
        lock.withLock {
            if let b = snapshot?.brightness { return b }
            // Not taken over: cache the live read (refresh at ~2 Hz) so a 120 Hz caller does not hit the client.
            let now = CFAbsoluteTimeGetCurrent()
            if now - liveReadAt > 0.5 { liveRead = client?.brightness(forKeyboard: kbID) ?? 0; liveReadAt = now }
            return liveRead
        }
    }
    private var liveRead: Float = 0
    private var liveReadAt: CFAbsoluteTime = 0
    /// Last user brightness observed while the backlight was not dimmed/suppressed.
    nonisolated(unsafe) private static var lastGoodBrightness: Float = 0

    private func responds(_ s: String) -> Bool { raw?.responds(to: NSSelectorFromString(s)) ?? false }

    // MARK: take over / restore

    /// Snapshot user state to disk (crash-safe), disable ambient auto-brightness, and if
    /// `keepAwake` suspend the 5 s idle dimming. Idempotent.
    func takeOver(keepAwake: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let c = client, !sealed else { return }
        if taken {
            self.keepAwake = keepAwake
            if responds("suspendIdleDimming:forKeyboard:") { _ = c.suspendIdleDimming(keepAwake, forKeyboard: kbID) }
            return
        }
        // "suppressed" alone also reads true at brightness 0 (measured), so only "dimmed" marks a masked level.
        func isTransient() -> Bool { responds("isBacklightDimmedOnKeyboard:") && c.isBacklightDimmed(onKeyboard: kbID) }
        var liveB = c.brightness(forKeyboard: kbID)
        var transient = isTransient()
        if transient {
            // The 5 s idle dim reads back as brightness 0, which would be "restored" as the user's level.
            // Suspending idle dimming un-dims at once (measured), so the true level can be read.
            _ = c.suspendIdleDimming(true, forKeyboard: kbID)
            for _ in 0..<10 { usleep(50_000); if !isTransient() { break } }
            liveB = c.brightness(forKeyboard: kbID)
            transient = isTransient()
        }
        if Self.lastGoodBrightness <= 0.01 { Self.lastGoodBrightness = Float(UserDefaults.standard.double(forKey: "backlightLastGood")) }
        if transient && Self.lastGoodBrightness > 0.01 { liveB = Self.lastGoodBrightness }
        else if !transient && liveB > 0.01 {
            Self.lastGoodBrightness = liveB
            UserDefaults.standard.set(Double(liveB), forKey: "backlightLastGood")
        }
        let snap = BacklightSnapshot(brightness: liveB,
                                     autoBrightnessEnabled: c.isAutoBrightnessEnabled(forKeyboard: kbID),
                                     idleDimTime: c.idleDimTime(forKeyboard: kbID),
                                     capturedAt: Date(), pid: getpid())
        snapshot = snap
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: Self.snapshotURL, options: .atomic) }
        _ = c.enableAutoBrightness(false, forKeyboard: kbID)
        _ = c.suspendIdleDimming(keepAwake, forKeyboard: kbID)
        self.keepAwake = keepAwake
        taken = true
        lastLevel = -1
        glide = .lit; lastValue = -1; lastPlainV = -1
        lastDuty = liveB < 0.0005 ? Self.offDuty : Self.floorDuty + 282 * Double(max(liveB, 0))
        prevDT = 0
        Log.write(String(format: "[backlight] took over id=%llu saved brightness=%.3f auto=%@ idleDim=%.1f keepAwake=%@",
                         kbID, snap.brightness, snap.autoBrightnessEnabled ? "on" : "off", snap.idleDimTime,
                         keepAwake ? "yes" : "no"))
    }

    /// Change idle-dim suspension while taken over.
    func setKeepAwake(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard taken, let c = client, on != keepAwake else { return }
        keepAwake = on
        _ = c.suspendIdleDimming(on, forKeyboard: kbID)
    }

    /// Restore snapshot (idempotent). Called on stop, quit, sleep, signals. `seal` (signal path only) makes
    /// the driver refuse any later takeOver, so a render tick racing the dying process cannot re-grab the
    /// keyboard (auto-brightness off, idle dim suspended) after the user's state was handed back.
    func restore() { restore(seal: false) }
    func restore(seal: Bool) {
        lock.lock(); defer { lock.unlock() }
        if seal { sealed = true }
        guard taken, let snap = snapshot else { return }
        taken = false
        apply(snap)
        snapshot = nil
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        Log.write("[backlight] restored brightness=\(snap.brightness)")
    }

    /// Caller holds the lock. Final committed hand-back write: CoreBrightness dedupes a write equal to its own
    /// last value, and after fade-0/no-commit writes its value can differ from what the panel shows (or equal
    /// the target while the panel is lit), so a different throwaway value goes first. The real write is
    /// committed and glides from the live duty (corebrightnessd runs the ramp, so the process may exit).
    /// The readback is then checked so CoreBrightness and the panel agree on the user's level.
    private func setCommitted(_ b: Float, _ c: KBClient) {
        let nudge: Float = b > 0.5 ? b - 0.01 : (b > 0 ? b + 0.01 : 0.0045)
        _ = c.setBrightness(nudge, forKeyboard: kbID)
        if b > 0, useFadeVariant { _ = c.setBrightness(b, fadeSpeed: 300, commit: true, forKeyboard: kbID) }
        else { _ = c.setBrightness(b, forKeyboard: kbID) }
        if abs(c.brightness(forKeyboard: kbID) - b) > 0.004 {
            _ = c.setBrightness(nudge, forKeyboard: kbID)
            _ = c.setBrightness(b, forKeyboard: kbID)
        }
    }

    /// Caller holds the lock. Brightness is written last so ambient re-enable cannot override it.
    private func apply(_ s: BacklightSnapshot) {
        guard let c = client else { return }
        _ = c.suspendIdleDimming(false, forKeyboard: kbID)
        _ = c.setIdleDimTime(s.idleDimTime, forKeyboard: kbID)
        _ = c.enableAutoBrightness(s.autoBrightnessEnabled, forKeyboard: kbID)
        setCommitted(s.brightness, c)
        if s.brightness <= 0 {
            // Plain off ramps ~350-450 ms (distance / 0.45 s); exiting mid-ramp parks the panel at a faint duty.
            usleep(150_000)
            // The settled off duty varies (2...11 measured), so stop when low or no longer moving.
            var prev = -1
            for _ in 0..<14 {
                let h = Self.readPWM()?.high ?? 0
                if h <= 12 || h == prev { break }
                prev = h; usleep(50_000)
            }
        }
        lastLevel = -1; lastValue = -1; isOff = false; glide = .lit; lastPlainV = -1
    }

    /// On launch: if a snapshot from a crashed run exists, restore it.
    static func recoverIfNeeded() {
        let d = shared
        guard d.client != nil,
              let data = try? Data(contentsOf: snapshotURL),
              let stale = try? JSONDecoder().decode(BacklightSnapshot.self, from: data) else { return }
        if stale.pid != getpid(), kill(stale.pid, 0) == 0 || errno == EPERM { return }   // owner still alive
        d.lock.lock()
        if !d.taken { d.apply(stale) }
        d.lock.unlock()
        try? FileManager.default.removeItem(at: snapshotURL)
        Log.write("[backlight] recovered snapshot of dead pid \(stale.pid)")
    }

    // MARK: writes

    /// CoreBrightness value -> fraction of maximum light (duty 54 + 282 v of 336).
    /// A value of 0 is the true off (duty 6), not the lit floor: handing back from / entering a dark keyboard
    /// must start dark.
    static let offLight = Float(offDuty / maxDuty)
    static func lightFor(_ v: Float) -> Float {
        v < 0.0005 ? offLight : Float((floorDuty + 282 * Double(min(max(v, 0), 1))) / maxDuty)
    }
    /// Fraction of maximum light -> CoreBrightness value (0 below the lit floor).
    static func valueFor(_ light: Float) -> Float { max(0, Float((maxDuty * Double(light) - floorDuty) / 282)) }

    /// Legacy value-domain write (0...1 CoreBrightness value, exact 0 = off).
    func write(_ level: Float) {
        let v = level.isNaN ? 0 : min(max(level, 0), 1)
        writeLight(v < 0.0005 ? 0 : Self.lightFor(v))
    }

    /// Fast write, any thread. `light` is the fraction of maximum light (PWM duty / 336), so a perceptual
    /// curve can be applied by the caller and the whole range, including the dark band below the lit floor
    /// (duty 6...54), is continuous: lit levels use the instant fade0 write, the band uses a glide.
    func writeLight(_ light: Float) {
        lock.lock(); defer { lock.unlock() }
        guard taken, let c = client else { return }
        let now = hostNow()
        let d = Double(light.isNaN ? 0 : min(max(light, 0), 1)) * Self.maxDuty
        advanceModel(now)
        defer { prevD = d; prevDT = now }
        if d >= Self.floorDuty - 0.5 {
            if glide == .lit { litWrite(d, c); return }
            let slope = prevDT > 0 ? (d - prevD) / max(now - prevDT, 1e-3) : 0
            if dModel >= d - 3 || slope > 400 { litWrite(d, c); return }     // caught up, or a fast attack
            // slow rise out of the band and the glide has not arrived yet: let the ramp chase the target
            let t = d + max(slope, 0) * 0.3
            if glide == .down || (abs(t - cmdTarget) > 12 && now - cmdT > 0.06) {
                if glide == .down { turnD = d }
                glide = .up; plainWrite(t, c, now)
            }
            skipCount += 1
            return
        }
        // requested duty is inside the dark band
        if glide == .lit {
            dModel = lastDuty; modelT = now; glide = .down; turnD = d
            plainWrite(Self.offDuty, c, now)
            return
        }
        if glide == .down {
            turnD = min(turnD, d)
            if d > turnD + 2, now - cmdT > 0.06 { glide = .up; turnD = d; plainWrite(Self.floorDuty, c, now) }
        } else {
            turnD = max(turnD, d)
            if d < turnD - 2, now - cmdT > 0.06 { glide = .down; turnD = d; plainWrite(Self.offDuty, c, now) }
        }
        skipCount += 1
    }

    /// Caller holds the lock. Instant lit write (fade0, no commit) at duty `d` >= 54.
    private func litWrite(_ d: Double, _ c: KBClient) {
        let v = Float(max(0, (d - Self.floorDuty) / 282))
        if glide == .lit, lastValue >= 0, v == lastValue || abs(v - lastValue) < 1.0 / 4096 { skipCount += 1; lastDuty = d; return }
        let t0 = hostNow()
        let ok: Bool
        if useFadeVariant { ok = c.setBrightness(max(v, 0.0001), fadeSpeed: 0, commit: false, forKeyboard: kbID) }
        else { ok = c.setBrightness(max(v, 0.0001), forKeyboard: kbID) }
        noteWrite(hostNow() - t0)
        glide = .lit
        if ok { lastValue = v; isOff = false; lastLevel = Int((v * 255).rounded()); lastDuty = d }
    }

    /// Caller holds the lock. One plain (ramping) write toward duty `target` (6 = off, else >= 54).
    private func plainWrite(_ target: Double, _ c: KBClient, _ now: Double) {
        let t = target <= Self.offDuty + 0.5 ? Self.offDuty : max(target, Self.floorDuty)
        let v: Float = t <= Self.offDuty ? 0 : max(Float((t - Self.floorDuty) / 282), 0.0045)
        let t0 = hostNow()
        // corebrightnessd drops a write equal to its last plain value; a throwaway different one first.
        if v == lastPlainV { _ = c.setBrightness(v == 0 ? 0.0045 : 0, forKeyboard: kbID) }
        _ = c.setBrightness(v, forKeyboard: kbID)
        noteWrite(hostNow() - t0)
        lastPlainV = v; lastValue = -1; isOff = v == 0
        cmdT = now; cmdTarget = t
    }

    private func noteWrite(_ dt: Double) {
        totalWriteSeconds += dt
        ewmaWriteMs = ewmaWriteMs == 0 ? dt * 1000 : ewmaWriteMs * 0.98 + dt * 1000 * 0.02
        writeCount += 1
    }

    /// Caller holds the lock. Integrates the measured plain-ramp behaviour: 19 ms latency, then a linear ramp
    /// at ~107 ticks/s (48 ticks in ~0.45 s) that is faster for far targets (distance / 0.45 s).
    private func advanceModel(_ now: Double) {
        let prev = modelT
        modelT = now
        guard glide != .lit, now > prev else { return }
        let mt = now - max(prev, cmdT + 0.019)
        guard mt > 0 else { return }
        if cmdTarget < dModel { dModel = max(cmdTarget, dModel - max(100, (dModel - cmdTarget) / 0.45) * mt) }
        else { dModel = min(cmdTarget, dModel + max(90, (cmdTarget - dModel) / 0.45) * mt) }
    }

    /// Smoothed duration of one CoreBrightness write call (ms). ~0.03 ms measured.
    var writeLatencyMs: Double { lock.withLock { ewmaWriteMs } }

    /// One-line hardware description for diagnostics (reads the live PWM registers).
    var hardwareInfo: String {
        guard client != nil else { return "no keyboard backlight" }
        var s = "CoreBrightness fade0/no-commit"
        if let p = Self.readPWM() {
            s += String(format: ", PWM %d ticks @ %.0f kHz (~10-bit), duty %d (%.1f%%)", p.high + p.low,
                        p.freq / Double(p.high + p.low) / 1000, p.high, 100 * Double(p.high) / Double(p.high + p.low))
        }
        return s
    }

    private static func readPWM() -> (high: Int, low: Int, freq: Double)? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPWMDevice"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            var nm = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(e, &nm)
            guard String(cString: nm) == "kbd-backlight" else { continue }
            func num(_ k: String) -> Int? {
                (IORegistryEntryCreateCFProperty(e, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            if let h = num("high-period"), let l = num("low-period") { return (h, l, Double(num("pwm-frequency") ?? 24_000_000)) }
        }
        return nil
    }

    var lastWritten: Float { lock.withLock { lastValue < 0 ? 0 : lastValue } }

    func diagnostics() -> BacklightDiagnostics {
        lock.lock(); defer { lock.unlock() }
        var d = BacklightDiagnostics()
        guard let c = client else { return d }
        d.available = true
        d.keyboardID = kbID
        d.writes = writeCount
        d.skipped = skipCount
        d.lastWritten = lastValue < 0 ? 0 : lastValue
        d.systemLevel = c.brightness(forKeyboard: kbID)
        d.autoBrightness = c.isAutoBrightnessEnabled(forKeyboard: kbID)
        d.idleDimTime = c.idleDimTime(forKeyboard: kbID)
        if responds("isBacklightSuppressedOnKeyboard:") { d.suppressed = c.isBacklightSuppressed(onKeyboard: kbID) }
        if responds("isBacklightDimmedOnKeyboard:") { d.dimmed = c.isBacklightDimmed(onKeyboard: kbID) }
        if responds("isIdleDimmingSuspendedOnKeyboard:") { d.idleDimSuspended = c.isIdleDimmingSuspended(onKeyboard: kbID) }
        d.avgWriteMicros = writeCount > 0 ? totalWriteSeconds / Double(writeCount) * 1e6 : 0
        return d
    }
}
