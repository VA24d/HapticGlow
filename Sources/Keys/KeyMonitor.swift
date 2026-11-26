// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Listen-only CGEventTap on a dedicated userInteractive thread. Events go straight to KeyBus in the
// callback (no queue hops). Design after Clacky's listener (session tap, own run loop) and Thock's
// device-specific modifier masks (both MIT); re-enable logic follows Thock.
import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Synchronization

private let nxSystemDefinedTypeRaw: UInt32 = 14

final class KeyMonitor: @unchecked Sendable {
    static let shared = KeyMonitor()

    private let state = Locked<EngineStatus>(.stopped)
    var status: EngineStatus { state.get() }
    /// Called on the main queue when status changes.
    var onStatusChange: ((EngineStatus) -> Void)?

    /// Input Monitoring granted (CGPreflightListenEventAccess).
    static var hasPermission: Bool { CGPreflightListenEventAccess() }
    /// Shows the system prompt (CGRequestListenEventAccess).
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    /// Maps an IOKit `NX_KEYTYPE_*` code from an `NX_SYSDEFINED` aux event to its MacBook F-row virtual keycode.
    static func fRowKeyCode(forNXKey nxKey: Int) -> UInt16? {
        switch nxKey {
        case 3, 15: return 122       // NX_KEYTYPE_BRIGHTNESS_DOWN, VIDMIRROR -> F1
        case 2:     return 120       // NX_KEYTYPE_BRIGHTNESS_UP -> F2
        case 13:    return 118       // NX_KEYTYPE_LAUNCH_PANEL -> F4
        case 22:    return 96        // NX_KEYTYPE_ILLUMINATION_DOWN -> F5
        case 21, 23: return 97       // NX_KEYTYPE_ILLUMINATION_UP / TOGGLE -> F6
        case 18, 20: return 98       // NX_KEYTYPE_PREVIOUS / REWIND -> F7
        case 16:    return 100       // NX_KEYTYPE_PLAY -> F8
        case 17, 19: return 101      // NX_KEYTYPE_NEXT / FAST -> F9
        case 7:     return 109       // NX_KEYTYPE_MUTE -> F10
        case 1:     return 103       // NX_KEYTYPE_SOUND_DOWN -> F11
        case 0, 14: return 111       // NX_KEYTYPE_SOUND_UP, EJECT -> F12
        default:    return nil       // ignore NX_KEYTYPE_CAPS_LOCK (4) etc. (handled via flagsChanged)
        }
    }

    /// Decodes an `NX_SYSDEFINED` event (`subtype` + `data1`) into an F-row press/release event.
    static func decodeSystemDefined(subtype: Int16, data1: Int) -> (keyCode: UInt16, down: Bool, isRepeat: Bool)? {
        guard subtype == 8 else { return nil }   // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        let raw = UInt32(truncatingIfNeeded: data1)
        let nxKey = Int((raw >> 16) & 0xFFFF)
        let keyState = (raw >> 8) & 0xFF
        guard keyState == 0x0A || keyState == 0x0B else { return nil }
        guard let keyCode = fRowKeyCode(forNXKey: nxKey) else { return nil }
        let down = (keyState == 0x0A)
        let isRepeat = down && ((raw & 0x1) != 0)
        return (keyCode, down, isRepeat)
    }

    /// Maps Apple Silicon / HID special F-row keycodes (Mission Control, Spotlight, Dictation, DND, etc.) to F1-F12.
    static func mappedVirtualKeyCode(_ code: UInt16) -> UInt16 {
        switch code {
        case 145: return 122   // brightness down -> F1
        case 144: return 120   // brightness up -> F2
        case 160: return 99    // Mission Control -> F3
        case 131, 177: return 118 // Launchpad / Spotlight -> F4
        case 176: return 96    // Dictation -> F5
        case 178: return 97    // Do Not Disturb -> F6
        case 74:  return 109   // kVK_Mute -> F10
        case 73:  return 103   // kVK_VolumeDown -> F11
        case 72:  return 111   // kVK_VolumeUp -> F12
        default:  return code
        }
    }

    // Tap state (touched by tap thread; `tap` read by callback for re-enable).
    fileprivate var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let ctl = UnfairLock()
    /// Bumped on every start and stop; the main-queue publish of NX_SYSDEFINED keys drops events from an older run.
    fileprivate let runGen = Atomic<Int>(0)

    private func setStatus(_ s: EngineStatus) {
        let changed = state.get() != s
        state.set(s)
        if changed, let cb = onStatusChange { DispatchQueue.main.async { cb(s) } }
    }

    /// Starts the tap thread; publishes every event to KeyBus.shared. Returns false without permission.
    @discardableResult func start() -> Bool {
        ctl.lock(); defer { ctl.unlock() }
        if thread != nil, tap != nil { return true }
        guard Self.hasPermission else { setStatus(.needsPermission("Input Monitoring")); return false }
        setStatus(.starting)
        runGen.add(1, ordering: .acquiringAndReleasing)
        let ready = DispatchSemaphore(value: 0)
        let gate = StartGate()
        let th = Thread { [unowned self] in self.threadMain(ready: ready, gate: gate) }
        th.name = "HapticGlow.KeyTap"
        th.qualityOfService = .userInteractive
        thread = th
        th.start()
        _ = ready.wait(timeout: .now() + 2)
        if !gate.finishOrCancel() || tap == nil {   // late thread must not create a second tap
            thread = nil
            // Grant may need an app restart before the tap can be created.
            setStatus(.needsPermission("Input Monitoring"))
            return false
        }
        setStatus(.running)
        return true
    }

    func stop() {
        ctl.lock(); defer { ctl.unlock() }
        // Clear the tap first (under the lock) so reenable() is a no-op while the port is torn down.
        runGen.add(1, ordering: .acquiringAndReleasing)
        let t = tap, rl = runLoop
        tap = nil; runLoop = nil; thread = nil
        if let t { CGEvent.tapEnable(tap: t, enable: false) }
        if let rl { CFRunLoopStop(rl) }
        setStatus(.stopped)
    }

    private final class StartGate: @unchecked Sendable {
        private let l = NSLock(); private var st = 0   // 0 pending, 1 tap installed, 2 cancelled
        /// Caller (start) after its wait: true if the tap thread finished, else cancels it.
        func finishOrCancel() -> Bool { l.lock(); defer { l.unlock() }; if st == 1 { return true }; st = 2; return false }
        /// Tap thread: true if it may install its tap (not cancelled).
        func install(_ body: () -> Void) -> Bool { l.lock(); defer { l.unlock() }; if st == 2 { return false }; body(); st = 1; return true }
        var cancelled: Bool { l.lock(); defer { l.unlock() }; return st == 2 }
    }

    private func threadMain(ready: DispatchSemaphore, gate: StartGate) {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << nxSystemDefinedTypeRaw)
        let info = Unmanaged.passUnretained(self).toOpaque()
        if gate.cancelled { ready.signal(); return }
        // HID-level tap sees events before the window server routes them (lowest latency). Listen-only at
        // either level needs only Input Monitoring; fall back to the session tap if the HID tap is refused.
        var level = "hid"
        var created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: keyTapCallback, userInfo: info)
        if created == nil {
            level = "session"
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: keyTapCallback, userInfo: info)
        }
        guard let port = created else { ready.signal(); return }
        Log.write("[keys] event tap level: \(level)")
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, src, .commonModes)
        let ok = gate.install { tap = port; runLoop = rl }
        if !ok {
            CFRunLoopRemoveSource(rl, src, .commonModes); CFMachPortInvalidate(port); ready.signal(); return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        ready.signal()
        CFRunLoopRun()
        CFRunLoopRemoveSource(rl, src, .commonModes)
        CFMachPortInvalidate(port)
    }

    fileprivate func reenable() {
        ctl.lock(); defer { ctl.unlock() }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }
}

// Device-specific modifier masks (IOKit NX_DEVICE*KEYMASK) as found in CGEventFlags raw value.
private let modMasks: [UInt16: UInt64] = [
    56: 0x02, 60: 0x04,      // left/right shift
    59: 0x01, 62: 0x2000,    // left/right control
    58: 0x20, 61: 0x40,      // left/right option
    55: 0x08, 54: 0x10,      // left/right command
]
private let maskSecondaryFn: UInt64 = 0x800000
private let flagCapsLock: UInt64 = 0x10000

/// Per-modifier last-known state (tap thread only).
private nonisolated(unsafe) var modDown = [Bool](repeating: false, count: 256)

/// Last emit time per (key code, direction), tap thread only. Some hardware sends an F-row key both as a
/// regular key event and as NX_SYSDEFINED; the second report within this window is dropped.
private nonisolated(unsafe) var lastEmit = [Double](repeating: -1, count: 512)
private let dupWindow = 0.03
/// Guards `lastEmit`: the tap thread checks normal F-keys and the main thread checks decoded
/// NX_SYSDEFINED keys, so both can touch it.
private let dupLock = NSLock()
@inline(__always) private func isDuplicate(code: UInt16, down: Bool, rep: Bool, now: Double) -> Bool {
    if rep { return false }
    let i = Int(code & 0xFF) * 2 + (down ? 1 : 0)
    dupLock.lock(); defer { dupLock.unlock() }
    let dup = abs(now - lastEmit[i]) < dupWindow
    // A main-queue hop delivers older timestamps late; only ever move the stamp forward.
    if now > lastEmit[i] { lastEmit[i] = now }
    return dup
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let info { Unmanaged<KeyMonitor>.fromOpaque(info).takeUnretainedValue().reenable() }
        for i in 0..<modDown.count { modDown[i] = false }
        return passthrough
    case .keyDown, .keyUp, .flagsChanged: break
    default:
        if type.rawValue == nxSystemDefinedTypeRaw, let copy = event.copy() {
            // NSEvent(cgEvent:) must run on the main thread: for Caps Lock it calls into HIToolbox,
            // which asserts the main queue and crashed the app (EXC_BREAKPOINT on HapticGlow.KeyTap).
            // Decode a copy there; the key time is taken here so sound timing is unaffected.
            let now = hostNow()
            let mon = info.map { Unmanaged<KeyMonitor>.fromOpaque($0).takeUnretainedValue() }
            let gen = mon?.runGen.load(ordering: .acquiring) ?? 0
            DispatchQueue.main.async {
                guard let mon, mon.runGen.load(ordering: .acquiring) == gen,
                      let ns = NSEvent(cgEvent: copy), ns.type == .systemDefined,
                      let d = KeyMonitor.decodeSystemDefined(subtype: ns.subtype.rawValue, data1: ns.data1) else { return }
                if isDuplicate(code: d.keyCode, down: d.down, rep: d.isRepeat, now: now) { return }
                let pos = KeyLayout.position(for: d.keyCode)
                KeyBus.shared.publish(KeyEvent(keyCode: d.keyCode, down: d.down, isRepeat: d.isRepeat,
                                               time: now, kind: pos.kind, row: pos.row, x: pos.x, y: pos.y))
            }
        }
        return passthrough
    }

    let now = hostNow()
    let rawCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let code = (type == .flagsChanged) ? rawCode : KeyMonitor.mappedVirtualKeyCode(rawCode)
    let pos = KeyLayout.position(for: code)

    func emit(down: Bool, rep: Bool, kind: KeyKind) {
        if kind == .function, isDuplicate(code: code, down: down, rep: rep, now: now) { return }
        KeyBus.shared.publish(KeyEvent(keyCode: code, down: down, isRepeat: rep, time: now, kind: kind,
                                       row: pos.row, x: pos.x, y: pos.y))
    }

    if type == .flagsChanged {
        let raw = event.flags.rawValue
        if let mask = modMasks[code] {
            let down = (raw & mask) != 0
            if down != modDown[Int(code & 0xFF)] {
                modDown[Int(code & 0xFF)] = down
                emit(down: down, rep: false, kind: .modifier)
            }
        } else if code == 57 {
            // Caps Lock is a toggle: every change is a physical press; emit down+up.
            emit(down: true, rep: false, kind: .capsLock)
            emit(down: false, rep: false, kind: .capsLock)
        } else if code == 63 {
            let down = (raw & maskSecondaryFn) != 0
            if down != modDown[63] { modDown[63] = down; emit(down: down, rep: false, kind: .fn) }
        }
        return passthrough
    }

    let rep = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    emit(down: type == .keyDown, rep: rep, kind: pos.kind)
    return passthrough
}
