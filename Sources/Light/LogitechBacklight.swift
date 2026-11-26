// Logitech keyboard backlight (MX Keys family) over HID++ 2.0, feature BACKLIGHT2 (0x1982).
//
// Transport: the keyboard's vendor collection (usage page 0xFF43, usage 0x0202) takes 20-byte
// "long" reports with id 0x11: [0x11, deviceIndex, featureIndex, function<<4 | swId, params...].
// Over Bluetooth LE the device index is 0xFF. Opening the device needs Input Monitoring, which
// HapticGlow already has for key sounds.
//
// BACKLIGHT2 layout (as documented by the open-source Solaar project):
//   fn 0 getBacklightConfig -> enabled, options, supported, effects(u16), level, dho(u16), dhi(u16), dpow(u16)
//   fn 1 setBacklightConfig <- enabled, options, 0xFF, level, dho, dhi, dpow
//   fn 2 getBacklightLevels -> number of levels
//   options bits 3-4 = mode (0 off, 1 auto, 3 manual); the level only applies in manual mode.
//   durations (dho, dhi, dpow) are little-endian u16 in 5-SECOND units (Solaar settings_templates.py
//   Backlight2Duration: read multiplies by 5, write divides by 5; UI max 600 s, "actual maximum is 2 hours"
//   = 7200 s = 1440 = 0x05a0). Stock MX Keys defaults 3/6/60 = 15 s / 30 s / 5 min.
import Foundation
import IOKit.hid

enum HIDPPError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    case removed
    case setReportFailed(IOReturn)
    case timeout(feature: UInt8, function: UInt8)
    case hidpp(feature: UInt8, function: UInt8, code: UInt8)
    case shortReply(Int)

    var isTimeout: Bool { if case .timeout = self { return true }; return false }
    /// HID++ Busy: the device is occupied, try again shortly.
    var isBusy: Bool { if case .hidpp(_, _, let code) = self { return code == 0x08 }; return false }
    /// InvalidArgument / OutOfRange: the device refused the value itself.
    var isExplicitReject: Bool { if case .hidpp(_, _, let code) = self { return code == 0x02 || code == 0x03 }; return false }

    var isDisconnectLike: Bool {
        switch self {
        case .openFailed, .removed, .setReportFailed, .timeout: return true
        case .hidpp(_, _, let code): return code == 0x06 // InvalidFeatureIndex
        case .shortReply: return false
        }
    }

    var description: String {
        switch self {
        case .openFailed(let rc):
            return String(format: "IOHIDDeviceOpen 0x%08x", UInt32(bitPattern: rc))
        case .removed:
            return "device removed"
        case .setReportFailed(let rc):
            return String(format: "IOHIDDeviceSetReport 0x%08x", UInt32(bitPattern: rc))
        case .timeout(let feat, let fn):
            return String(format: "timeout feat=0x%02x fn=%u", feat, fn)
        case .hidpp(let feat, let fn, let code):
            return String(format: "HID++ err feat=0x%02x fn=%u code=0x%02x (%@)",
                          feat, fn, code, Self.errorName(code))
        case .shortReply(let count):
            return "short reply (\(count) bytes)"
        }
    }

    static func errorName(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "NoError"
        case 0x01: return "Unknown"
        case 0x02: return "InvalidArgument"
        case 0x03: return "OutOfRange"
        case 0x04: return "HardwareError"
        case 0x05: return "LogitechInternal"
        case 0x06: return "InvalidFeatureIndex"
        case 0x07: return "InvalidFunctionID"
        case 0x08: return "Busy"
        case 0x09: return "Unsupported"
        default: return String(format: "0x%02x", code)
        }
    }
}

final class HIDPPDevice: @unchecked Sendable {
    let device: IOHIDDevice
    let name: String
    let serial: String
    var storageKey: String {
        serial.isEmpty ? "logiOriginal.\(name)" : "logiOriginal.\(name).\(serial)"
    }

    private let reqLock = NSLock()
    private let cond = NSCondition()
    private var reply: [UInt8]?
    private var waitingFeature: UInt8 = 0xFF
    private var waitingFunction: UInt8 = 0
    private var waitingSwId: UInt8 = 0
    private var nextSwId: UInt8 = UInt8((abs(Int(ProcessInfo.processInfo.processIdentifier)) % 14) + 1)
    private var removed = false
    private var closed = false
    /// Called (on the HID thread, outside any lock) for every vendor report that is not the reply to our own
    /// pending request: a keyboard that just woke talks first.
    var onUnsolicited: (@Sendable () -> Void)? {
        get { cond.lock(); defer { cond.unlock() }; return _onUnsolicited }
        set { cond.lock(); _onUnsolicited = newValue; cond.unlock() }
    }
    private var _onUnsolicited: (@Sendable () -> Void)?
    private let unsolicitedAtBox = Locked<Double>(0)
    /// hostNow() of the last unsolicited vendor report (0 = none yet).
    var lastUnsolicitedAt: Double { unsolicitedAtBox.get() }
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

    var isRemoved: Bool {
        cond.lock(); defer { cond.unlock() }
        return removed || closed
    }

    private init(_ d: IOHIDDevice, name: String, serial: String) {
        self.device = d
        self.name = name
        self.serial = serial
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, _, _, id, r, l in
            guard let ctx else { return }
            let me = Unmanaged<HIDPPDevice>.fromOpaque(ctx).takeUnretainedValue()
            var b = Array(UnsafeBufferPointer(start: r, count: l))
            if b.first != 0x11 { b.insert(UInt8(truncatingIfNeeded: id), at: 0) }
            me.deliver(b)
        }, ctx)
        IOHIDDeviceRegisterRemovalCallback(d, { ctx, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDPPDevice>.fromOpaque(ctx).takeUnretainedValue().markRemoved()
        }, ctx)
        HIDPPDevice.ioThread.schedule(d)
    }

    static func open(_ d: IOHIDDevice) -> Result<HIDPPDevice, HIDPPError> {
        let rc = IOHIDDeviceOpen(d, 0)
        guard rc == kIOReturnSuccess else { return .failure(.openFailed(rc)) }
        let rawName = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? "Logitech keyboard" : rawName
        let serial = (IOHIDDeviceGetProperty(d, kIOHIDSerialNumberKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(HIDPPDevice(d, name: name, serial: serial))
    }

    func close() {
        cond.lock()
        let already = closed
        closed = true
        cond.broadcast()
        cond.unlock()
        guard !already else { return }
        HIDPPDevice.ioThread.unschedule(device, buf: buf)
        IOHIDDeviceClose(device, 0)
    }

    deinit {
        close()
        buf.deallocate()
    }

    private func markRemoved() {
        cond.lock()
        removed = true
        cond.broadcast()
        cond.unlock()
    }

    private func deliver(_ b: [UInt8]) {
        var matched = false
        var hook: (@Sendable () -> Void)?
        cond.lock()
        if b.count >= 4, b[0] == 0x11 {
            let f = waitingFeature
            let fn = waitingFunction
            let sw = waitingSwId
            if sw != 0 {
                let expectedFnSw = (fn << 4) | sw
                let isNormal = b[2] == f && b[3] == expectedFnSw
                let isError = b.count >= 6 && b[2] == 0xFF && b[3] == f && b[4] == expectedFnSw
                if isNormal || isError {
                    reply = b
                    matched = true
                    cond.signal()
                }
            }
        }
        if !matched { hook = _onUnsolicited }
        cond.unlock()
        if !matched {
            unsolicitedAtBox.set(hostNow())
            hook?()
        }
    }

    /// Synchronous HID++ 2.0 request. Returns parameter bytes or a typed HIDPPError.
    func requestResult(feature: UInt8, function: UInt8, params: [UInt8] = [], timeout: Double = 1.0) -> Result<[UInt8], HIDPPError> {
        reqLock.lock(); defer { reqLock.unlock() }
        let swId = nextSwId
        nextSwId = (nextSwId % 15) + 1

        var r = [UInt8](repeating: 0, count: 20)
        r[0] = 0x11; r[1] = 0xFF; r[2] = feature; r[3] = (function << 4) | swId
        for (i, p) in params.prefix(16).enumerated() { r[4 + i] = p }

        cond.lock()
        if removed || closed { cond.unlock(); return .failure(.removed) }
        reply = nil
        waitingFeature = feature
        waitingFunction = function
        waitingSwId = swId
        cond.unlock()

        defer {
            cond.lock()
            waitingFeature = 0xFF
            waitingFunction = 0
            waitingSwId = 0
            cond.unlock()
        }

        let rc = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, r, r.count)
        guard rc == kIOReturnSuccess else {
            if rc == kIOReturnNotAttached || rc == kIOReturnOffline || rc == kIOReturnNoDevice {
                markRemoved()
            }
            return .failure(.setReportFailed(rc))
        }

        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while reply == nil {
            if removed || closed { return .failure(.removed) }
            if !cond.wait(until: deadline) { return .failure(.timeout(feature: feature, function: function)) }
        }
        guard let b = reply else { return .failure(.timeout(feature: feature, function: function)) }
        if b[2] == 0xFF {
            let errFeat = b.count > 3 ? b[3] : feature
            let errFn = b.count > 4 ? (b[4] >> 4) : function
            let errCode = b.count > 5 ? b[5] : 0x01
            return .failure(.hidpp(feature: errFeat, function: errFn, code: errCode))
        }
        guard b.count >= 5 else { return .failure(.shortReply(b.count)) }
        return .success(Array(b[4...]))
    }

    func request(feature: UInt8, function: UInt8, params: [UInt8] = [], timeout: Double = 1.0) -> [UInt8]? {
        if case .success(let bytes) = requestResult(feature: feature, function: function, params: params, timeout: timeout) {
            return bytes
        }
        return nil
    }

    func featureIndexResult(_ id: UInt16, timeout: Double = 0.6) -> Result<UInt8?, HIDPPError> {
        switch requestResult(feature: 0x00, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)], timeout: timeout) {
        case .success(let r):
            guard let idx = r.first, idx != 0 else { return .success(nil) }
            return .success(idx)
        case .failure(let e):
            return .failure(e)
        }
    }

    func featureIndex(_ id: UInt16, timeout: Double = 0.6) -> UInt8? {
        if case .success(let idx) = featureIndexResult(id, timeout: timeout) { return idx }
        return nil
    }

    /// One run loop thread for all HID++ devices; input reports and removal callbacks are delivered there.
    final class IOThread: @unchecked Sendable {
        private var rl: CFRunLoop?
        private var thread: Thread?
        private let ready = DispatchSemaphore(value: 0)
        init() {
            let t = Thread { [unowned self] in
                self.rl = CFRunLoopGetCurrent()
                var ctx = CFRunLoopSourceContext()
                let keep = CFRunLoopSourceCreate(nil, 0, &ctx)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), keep, .defaultMode)
                self.ready.signal()
                CFRunLoopRun()
            }
            t.name = "HapticGlow.hidpp"; t.qualityOfService = .userInitiated
            self.thread = t
            t.start()
            ready.wait()
        }
        func schedule(_ d: IOHIDDevice) {
            guard let rl else { return }
            if Thread.current === thread {
                IOHIDDeviceScheduleWithRunLoop(d, rl, CFRunLoopMode.defaultMode.rawValue)
                return
            }
            let sem = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
                IOHIDDeviceScheduleWithRunLoop(d, rl, CFRunLoopMode.defaultMode.rawValue)
                sem.signal()
            }
            CFRunLoopWakeUp(rl)
            sem.wait()
        }
        func unschedule(_ d: IOHIDDevice, buf: UnsafeMutablePointer<UInt8>) {
            guard let rl else { return }
            let work = {
                IOHIDDeviceRegisterInputReportCallback(d, buf, 0, nil, nil)
                IOHIDDeviceRegisterRemovalCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, rl, CFRunLoopMode.defaultMode.rawValue)
            }
            if Thread.current === thread {
                work()
                return
            }
            let sem = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
                work()
                sem.signal()
            }
            CFRunLoopWakeUp(rl)
            sem.wait()
        }
        func scheduleManager(_ m: IOHIDManager) {
            guard let rl else { return }
            if Thread.current === thread {
                IOHIDManagerScheduleWithRunLoop(m, rl, CFRunLoopMode.defaultMode.rawValue)
                return
            }
            let sem = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
                IOHIDManagerScheduleWithRunLoop(m, rl, CFRunLoopMode.defaultMode.rawValue)
                sem.signal()
            }
            CFRunLoopWakeUp(rl)
            sem.wait()
        }
        func unscheduleManager(_ m: IOHIDManager) {
            guard let rl else { return }
            let work = {
                IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
                IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
                IOHIDManagerRegisterInputReportCallback(m, nil, nil)
                IOHIDManagerUnscheduleFromRunLoop(m, rl, CFRunLoopMode.defaultMode.rawValue)
            }
            if Thread.current === thread {
                work()
                return
            }
            let sem = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {
                work()
                sem.signal()
            }
            CFRunLoopWakeUp(rl)
            sem.wait()
        }
    }
    static let ioThread = IOThread()
}

final class LogitechBacklight: @unchecked Sendable {
    static let shared = LogitechBacklight()

    private static let durationCandidates: [UInt16] = [1440, 1200, 900, 720, 360, 180, 120, 60, 36, 24, 12]
    private static let verifyInterval: Double = 60
    private static let quietVerifyInterval: Double = 300
    private static let maxRuntimeDuration: UInt16 = 1440   // 2 h in 5 s units; the MX Keys rejects more
    private static let quietAfter: Double = 300
    private static let minBackoff: Double = 2.0
    private static let maxBackoff: Double = 30.0
    private static let minWriteFloor: Double = 0.036

    struct Keyboard {
        let hid: HIDPPDevice
        let feature: UInt8
        let levels: Int
        let baseConfig: [UInt8]         // live config read at discovery (12 bytes)
        let original: [UInt8]?          // user's non-manual config (persisted in UserDefaults)
        var engagedDurations: [UInt8]?  // 6 bytes: dho(u16 LE), dhi(u16 LE), dpow(u16 LE) in 5s units
        var lastLevel: Int = -1
        var dirty: Bool = false
        var wantLevel: Int = -1         // newest level asked for, even if the keyboard was asleep for it
        var stale: Bool = false         // keyboard stopped answering (asleep); retry with backoff
        var staleAt: Double = 0
        var wakeAttemptedAt: Double = 0
        var nextRetryAt: Double = 0
        var retryDelay: Double = 1
        var lastVerify: Double = 0
        var lastChangeAt: Double = 0
        var pendingRestore: Bool = false // restore failed (asleep); retry when it wakes, while not engaged
        var quitFailed: Bool = false     // restoreForQuit timed out on this board; do not retry within the quit
    }

    private struct BoardID { let serial: String; let product: String; let location: Int }
    private let knownIDs = Locked<[BoardID]>([])
    private let sealedBox = Locked<Bool>(false)
    private var isSealed: Bool { sealedBox.get() }
    private var reprobed = Set<String>()   // devices whose max duration was re-probed this launch (under `lock`)

    private let anyStale = Locked<Bool>(false)
    private let nextRetryBox = Locked<Double?>(nil)
    private let managerActivityAt = Locked<Double>(0)

    private static func maxDurKey(_ h: HIDPPDevice) -> String { "logiMaxDuration.v2.\(h.storageKey)" }

    private func noteActivity() {
        guard anyStale.get() else { return }
        wcond.lock(); housekeepFlag = true; wcond.signal(); wcond.unlock()
    }

    private func noteManagerActivity(from dev: IOHIDDevice) {
        guard anyStale.get(), isKnownBoardReport(dev) else { return }
        managerActivityAt.set(hostNow())
        noteActivity()
    }

    /// True for a report from a known board's own interfaces or from a keyboard-class Logitech device.
    /// A Logitech mouse must not count as the sleeping keyboard waking up.
    private func isKnownBoardReport(_ dev: IOHIDDevice) -> Bool {
        func int(_ k: String) -> Int? { IOHIDDeviceGetProperty(dev, k as CFString) as? Int }
        if int(kIOHIDPrimaryUsagePageKey) == 0x01 && int(kIOHIDPrimaryUsageKey) == 0x06 { return true }
        let serial = ((IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let product = ((IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = int(kIOHIDLocationIDKey) ?? 0
        return knownIDs.get().contains { k in
            (!serial.isEmpty && serial == k.serial && product == k.product) || (loc != 0 && loc == k.location)
        }
    }

    private func latestActivity(for b: Keyboard) -> Double {
        max(b.hid.lastUnsolicitedAt, managerActivityAt.get())
    }

    private func updateKnownLocked() {
        knownIDs.set(boards.map { b in
            BoardID(serial: b.hid.serial, product: b.hid.name,
                    location: (IOHIDDeviceGetProperty(b.hid.device, kIOHIDLocationIDKey as CFString) as? Int) ?? 0)
        })
    }

    private func refreshAnyStaleLocked() {
        anyStale.set(boards.contains { $0.stale || $0.pendingRestore })
        nextRetryBox.set(nextStaleRetryLocked())

    }

    private func markStaleLocked(_ i: Int, now: Double = hostNow()) {
        let first = !boards[i].stale
        boards[i].stale = true
        if first { boards[i].staleAt = now; boards[i].retryDelay = 1 }
        boards[i].nextRetryAt = now + boards[i].retryDelay
        boards[i].retryDelay = min(boards[i].retryDelay * 2, 30)
        boards[i].lastLevel = -1
        refreshAnyStaleLocked()
        if first {
            Log.write("[logi] \(boards[i].hid.name): asleep (no reply); retrying with backoff, or at once when it talks")
        } else {
            logThrottled(key: "still-asleep.\(boards[i].hid.name)", msg: "[logi] \(boards[i].hid.name): still asleep", interval: 60)
        }
    }

    private func noteAwakeLocked(_ i: Int, level: Int, now: Double = hostNow()) {
        if boards[i].stale {
            boards[i].stale = false
            boards[i].wakeAttemptedAt = 0
            boards[i].retryDelay = 1
            refreshAnyStaleLocked()
            Log.write("[logi] \(boards[i].hid.name): awake; resent manual level \(level) after \(String(format: "%.1f", now - boards[i].staleAt)) s")
        }
        boards[i].lastVerify = now
        if anyStale.get() { refreshAnyStaleLocked() }
    }

    private let discoverLock = NSLock()
    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var boards: [Keyboard] = []

    var keyboardNames: [String] { lock.withLock { boards.map(\.hid.name) } }
    var levelCount: Int { lock.withLock { boards.map(\.levels).max() ?? 0 } }

    private static func mode(of cfg: [UInt8]) -> Int {
        cfg.count > 1 ? Int((cfg[1] >> 3) & 0x03) : 0
    }

    private static func isManualConfig(_ cfg: [UInt8]) -> Bool {
        mode(of: cfg) == 3
    }

    private static func u16LE(_ a: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(a[offset]) | (UInt16(a[offset + 1]) << 8)
    }

    private static func durationBytes(dho: UInt16, dhi: UInt16, dpow: UInt16) -> [UInt8] {
        [UInt8(dho & 0xFF), UInt8(dho >> 8),
         UInt8(dhi & 0xFF), UInt8(dhi >> 8),
         UInt8(dpow & 0xFF), UInt8(dpow >> 8)]
    }

    private static func loadSavedSnapshot(for key: String) -> [UInt8]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let arr = [UInt8](data)
        return arr.count == 12 ? arr : nil
    }

    private static func dirtyKey(_ h: HIDPPDevice) -> String { "\(h.storageKey).engaged" }

    /// Persists "HapticGlow has put this keyboard in manual mode" so a crashed run can be told from a clean one.
    private static func persistEngaged(_ h: HIDPPDevice, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: dirtyKey(h))
    }

    private func closeCurrentBoardsLocked() {
        for b in boards { b.hid.close() }
        boards.removeAll()
        refreshAnyStaleLocked()
        updateKnownLocked()
        connBox.set(false)
    }

    private func ensureManagerLocked(diag: ((String) -> Void)?) -> IOHIDManager? {
        if let m = manager { return m }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            let pairs = (IOHIDDeviceGetProperty(dev, "DeviceUsagePairs" as CFString) as? [[String: Int]]) ?? []
            guard pairs.contains(where: { $0["DeviceUsagePage"] == 0xFF43 }) else { return }
            let me = Unmanaged<LogitechBacklight>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.global(qos: .userInitiated).async { me.handleDeviceMatched(dev) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            guard let ctx else { return }
            let me = Unmanaged<LogitechBacklight>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.global(qos: .userInitiated).async { me.handleDeviceRemoved(dev) }
        }, ctx)
        IOHIDManagerRegisterInputReportCallback(m, { ctx, _, sender, _, id, _, _ in
            guard let ctx, let sender, id != 0x11 else { return }
            let dev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let me = Unmanaged<LogitechBacklight>.fromOpaque(ctx).takeUnretainedValue()
            me.noteManagerActivity(from: dev)
        }, ctx)
        HIDPPDevice.ioThread.scheduleManager(m)
        let rc = IOHIDManagerOpen(m, 0)
        if rc != kIOReturnSuccess {
            let msg = String(format: "[logi] manager open 0x%08x (Input Monitoring?)", UInt32(bitPattern: rc))
            logThrottled(key: "mgr-\(rc)", msg: msg); diag?(msg)
            HIDPPDevice.ioThread.unscheduleManager(m)
            IOHIDManagerClose(m, 0)
            return nil
        }
        manager = m
        return m
    }

    private func handleDeviceMatched(_ dev: IOHIDDevice) {
        guard !isSealed else { return }
        let prod = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Logitech"
        discoverLock.lock()
        guard !isSealed else { discoverLock.unlock(); return }
        let alreadyOpen = lock.withLock {
            boards.contains { CFEqual($0.hid.device, dev) && !$0.hid.isRemoved }
        }
        guard !alreadyOpen else {
            discoverLock.unlock()
            return
        }
        Log.write("[logi] \(prod): HID device re-matched; rescanning")
        wcond.withLock {
            nextDiscoverAt = 0
            backoffSeconds = Self.minBackoff
        }
        let found = discoverLocked(diag: nil)
        discoverLock.unlock()
        guard !found.isEmpty else { return }
        wcond.lock()
        if target < 0 && !wantRelease && resumePerceived >= 0 {
            target = resumePerceived
            wcond.signal()
        }
        wcond.unlock()
    }

    private func handleDeviceRemoved(_ dev: IOHIDDevice) {
        var removedNames: [String] = []
        var nowEmpty = false
        lock.lock()
        var kept: [Keyboard] = []
        for b in boards {
            if CFEqual(b.hid.device, dev) || b.hid.isRemoved {
                b.hid.close()
                removedNames.append(b.hid.name)
            } else {
                kept.append(b)
            }
        }
        if !removedNames.isEmpty {
            boards = kept
            refreshAnyStaleLocked()
            updateKnownLocked()
            nowEmpty = boards.isEmpty
            connBox.set(!nowEmpty)
        }
        lock.unlock()
        for name in removedNames {
            Log.write("[logi] \(name): disconnected (HID device removed)")
        }
        if nowEmpty {
            wcond.withLock {
                engaged = false
                nextDiscoverAt = 0
                backoffSeconds = Self.minBackoff
                wcond.signal()
            }
        }
    }

    /// Finds Logitech HID++ keyboards that support BACKLIGHT2. Calling it again rescans.
    @discardableResult func discover(diag: ((String) -> Void)? = nil) -> [String] {
        discoverLock.lock(); defer { discoverLock.unlock() }
        return discoverLocked(diag: diag)
    }

    @discardableResult private func discoverIfNeeded() -> [String] {
        discoverLock.lock(); defer { discoverLock.unlock() }
        if isConnected { return keyboardNames }
        return discoverLocked(diag: nil)
    }

    private func discoverLocked(diag: ((String) -> Void)?) -> [String] {
        guard !isSealed else { return [] }
        let hadBoards = lock.withLock { () -> Bool in
            let had = !boards.isEmpty
            closeCurrentBoardsLocked()
            return had
        }

        let m = ensureManagerLocked(diag: diag)
        let devs = (m.flatMap { IOHIDManagerCopyDevices($0) as? Set<IOHIDDevice> }) ?? []
        diag?("HID devices with vendor 0x046D: \(devs.count)")
        var found: [Keyboard] = []
        for d in devs {
            let prod = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "?"
            let pairs = (IOHIDDeviceGetProperty(d, "DeviceUsagePairs" as CFString) as? [[String: Int]]) ?? []
            guard pairs.contains(where: { $0["DeviceUsagePage"] == 0xFF43 }) else {
                diag?("skip \(prod): no 0xFF43 usage pair")
                continue
            }
            let h: HIDPPDevice
            switch HIDPPDevice.open(d) {
            case .success(let dev): h = dev
            case .failure(let err):
                let msg = "[logi] \(prod): open failed (\(err))"
                logThrottled(key: "open.\(prod)", msg: msg); diag?(msg)
                continue
            }
            h.onUnsolicited = { [weak self] in self?.noteActivity() }
            let fi: UInt8
            switch h.featureIndexResult(0x1982, timeout: 0.5) {
            case .success(let idx?): fi = idx
            case .success(nil):
                diag?("skip \(h.name): BACKLIGHT2 not supported")
                h.close()
                continue
            case .failure(let err):
                let msg = "[logi] \(h.name): featureIndex failed (\(err))"
                logThrottled(key: "fi.\(h.name)", msg: msg); diag?(msg)
                h.close()
                continue
            }
            let cfg: [UInt8]
            switch h.requestResult(feature: fi, function: 0, timeout: 0.5) {
            case .success(let bytes) where bytes.count >= 12:
                cfg = Array(bytes.prefix(12))
            case .success(let bytes):
                let msg = "[logi] \(h.name): getBacklightConfig short (\(bytes.count) bytes)"
                logThrottled(key: "cfg.\(h.name)", msg: msg); diag?(msg)
                h.close()
                continue
            case .failure(let err):
                let msg = "[logi] \(h.name): getBacklightConfig failed (\(err))"
                logThrottled(key: "cfg.\(h.name)", msg: msg); diag?(msg)
                h.close()
                continue
            }
            var lv = 0
            switch h.requestResult(feature: fi, function: 2, timeout: 0.5) {
            case .success(let bytes): lv = Int(bytes.first ?? 0)
            case .failure(let err):
                let msg = "[logi] \(h.name): getBacklightLevels failed (\(err))"
                logThrottled(key: "lv.\(h.name)", msg: msg); diag?(msg)
            }
            let levels = max(lv, 1)

            // The saved snapshot is trusted only if an earlier run left the keyboard engaged (dirty flag set,
            // or no flag yet from an older build and the keyboard is still in manual mode).
            let flagKey = Self.dirtyKey(h)
            let saved = Self.loadSavedSnapshot(for: h.storageKey)
            let flag = UserDefaults.standard.object(forKey: flagKey) as? Bool
            let wasDirty = flag ?? (saved != nil && Self.isManualConfig(cfg))
            let original: [UInt8]?
            let originNote: String
            if wasDirty, let saved, Self.isManualConfig(cfg) {
                original = saved
                originNote = "original(saved, previous run left it engaged)=\(Self.hex(saved))"
            } else if wasDirty, Self.isManualConfig(cfg) {
                // Left in manual mode by an earlier run and nothing saved: fall back to auto with the
                // stock durations (dho 3, dhi 6, dpow 60 in 5 s units). Not persisted, it is a guess.
                var guess = cfg
                guess[1] = (cfg[1] & ~UInt8(0x18)) | (1 << 3)
                guess[6] = 3; guess[7] = 0; guess[8] = 6; guess[9] = 0; guess[10] = 60; guess[11] = 0
                original = guess
                originNote = "original=guessed auto \(Self.hex(guess)) (found in manual mode, nothing saved; not persisting)"
            } else {
                // Not engaged by us: the live config (including the user's own manual mode) is the original.
                original = cfg
                UserDefaults.standard.set(Data(cfg), forKey: h.storageKey)
                UserDefaults.standard.set(false, forKey: flagKey)
                originNote = "original(captured)=\(Self.hex(cfg))"
            }

            let leftDirty = wasDirty && Self.isManualConfig(cfg)
            found.append(Keyboard(
                hid: h,
                feature: fi,
                levels: levels,
                baseConfig: cfg,
                original: original,
                engagedDurations: nil,
                lastLevel: -1,
                dirty: leftDirty
            ))
            Log.write("[logi] \(h.name) (\(h.serial)): BACKLIGHT2 index \(fi), \(levels) levels, live \(Self.hex(cfg)), \(originNote)")
        }

        lock.withLock {
            boards = found
            refreshAnyStaleLocked()
            updateKnownLocked()
            connBox.set(!found.isEmpty)
        }

        wcond.lock()
        if found.isEmpty {
            backoffSeconds = min(Self.maxBackoff, max(Self.minBackoff, backoffSeconds * 2))
            nextDiscoverAt = hostNow() + backoffSeconds
            if hadBoards { Log.write("[logi] keyboard disconnected; next scan in \(Int(backoffSeconds))s") }
        } else {
            backoffSeconds = Self.minBackoff
            nextDiscoverAt = 0
            fails = 0
        }
        wcond.unlock()

        return found.map(\.hid.name)
    }

    private func manualParams(for b: Keyboard, level: Int, durations: [UInt8]) -> [UInt8] {
        let base = b.original ?? b.baseConfig
        let manual = (base[1] & 0x07) | (0x03 << 3)
        return [1, manual, 0xFF, UInt8(level),
                durations[0], durations[1], durations[2], durations[3], durations[4], durations[5]]
    }

    /// Probes the longest backlight durations (dho/dhi/dpow) accepted by the device and writes `level`.
    /// Only an explicit invalid-argument / out-of-range reply counts as a rejection; Busy is retried and any
    /// other failure never lowers the cached maximum.
    private func probeAndWrite(board b: inout Keyboard, level: Int, errorOut: inout HIDPPError?) -> Bool {
        let base = b.original ?? b.baseConfig
        let origDpow = Self.u16LE(base, 10)
        let key = Self.maxDurKey(b.hid)
        let firstThisLaunch = reprobed.insert(key).inserted
        let cachedMax = UserDefaults.standard.integer(forKey: key)
        var candidates = Self.durationCandidates
        // A cached value below the runtime ceiling may come from an older run's transient failure: re-probe once per launch.
        if !firstThisLaunch, cachedMax >= 12, cachedMax < Int(Self.maxRuntimeDuration) {
            candidates = [UInt16(cachedMax)] + candidates.filter { $0 < UInt16(cachedMax) }
        }
        let reqTimeout = b.stale ? 0.5 : 1.0
        if !b.dirty { Self.persistEngaged(b.hid, true) }
        var onlyExplicitRejects = true
        for (idx, v) in candidates.enumerated() {
            if isSealed { return false }
            let dpow = max(v, origDpow)
            let dBytes = Self.durationBytes(dho: v, dhi: v, dpow: dpow)
            let p = manualParams(for: b, level: level, durations: dBytes)
            var result = b.hid.requestResult(feature: b.feature, function: 1, params: p, timeout: reqTimeout)
            var busyTries = 0
            while case .failure(let e) = result, e.isBusy, busyTries < 3, !isSealed {
                Thread.sleep(forTimeInterval: 0.03)
                result = b.hid.requestResult(feature: b.feature, function: 1, params: p, timeout: reqTimeout)
                busyTries += 1
            }
            switch result {
            case .success:
                var acceptedBytes = dBytes
                if case .success(let rb) = b.hid.requestResult(feature: b.feature, function: 0, timeout: 0.5), rb.count >= 12 {
                    let rbDho = Self.u16LE(rb, 6), rbDhi = Self.u16LE(rb, 8), rbDpow = Self.u16LE(rb, 10)
                    if rbDho >= 12 { acceptedBytes = Array(rb[6..<12]) }
                    Log.write("[logi] \(b.hid.name): engaged durations dho=\(rbDho) (\(Int(rbDho) * 5)s) dhi=\(rbDhi) (\(Int(rbDhi) * 5)s) dpow=\(rbDpow) (\(Int(rbDpow) * 5)s) (sent \(v))")
                } else {
                    Log.write("[logi] \(b.hid.name): engaged durations dho=\(v) (\(Int(v) * 5)s) dhi=\(v) (\(Int(v) * 5)s) dpow=\(dpow) (\(Int(dpow) * 5)s)")
                }
                b.engagedDurations = acceptedBytes
                if idx == 0 || onlyExplicitRejects {
                    UserDefaults.standard.set(Int(Self.u16LE(acceptedBytes, 0)), forKey: key)
                }
                b.lastLevel = level
                b.dirty = true
                return true
            case .failure(let err):
                if err.isDisconnectLike || err.isBusy {
                    errorOut = err
                    return false
                }
                if !err.isExplicitReject { onlyExplicitRejects = false }
                logThrottled(key: "dur.\(b.hid.name).\(v)", msg: "[logi] \(b.hid.name): duration \(v) rejected (\(err))")
            }
        }
        if isSealed { return false }
        // Fallback to original/base durations if all extended candidates were rejected.
        let fallback = Array(base[6..<12])
        let p = manualParams(for: b, level: level, durations: fallback)
        switch b.hid.requestResult(feature: b.feature, function: 1, params: p, timeout: reqTimeout) {
        case .success:
            b.engagedDurations = fallback
            b.lastLevel = level
            b.dirty = true
            return true
        case .failure(let err):
            errorOut = err
            return false
        }
    }

    /// Sends the engaged manual config at `level`. Caller holds `lock`. nil = success. A timeout marks the board stale.
    private func sendEngagedLocked(_ i: Int, level: Int, now: Double) -> HIDPPError? {
        let prev = boards[i].lastLevel
        if isSealed { return .timeout(feature: boards[i].feature, function: 1) }
        if let dBytes = boards[i].engagedDurations {
            if !boards[i].dirty { Self.persistEngaged(boards[i].hid, true) }
            let p = manualParams(for: boards[i], level: level, durations: dBytes)
            switch boards[i].hid.requestResult(feature: boards[i].feature, function: 1, params: p,
                                               timeout: boards[i].stale ? 0.5 : 1.0) {
            case .success:
                let doneAt = hostNow()
                boards[i].lastLevel = level
                boards[i].dirty = true
                boards[i].pendingRestore = false
                if level != prev { boards[i].lastChangeAt = doneAt }
                noteAwakeLocked(i, level: level, now: doneAt)
                return nil
            case .failure(let err):
                if err.isTimeout || boards[i].stale { markStaleLocked(i, now: hostNow()) }
                return err
            }
        }
        var probeErr: HIDPPError?
        if probeAndWrite(board: &boards[i], level: level, errorOut: &probeErr) {
            let doneAt = hostNow()
            boards[i].pendingRestore = false
            if level != prev { boards[i].lastChangeAt = doneAt }
            noteAwakeLocked(i, level: level, now: doneAt)
            return nil
        }
        if !isSealed, boards[i].stale || (probeErr?.isTimeout ?? false) { markStaleLocked(i, now: hostNow()) }
        return probeErr ?? .timeout(feature: boards[i].feature, function: 1)
    }

    /// Writer-thread upkeep while engaged: re-send after the keyboard wakes, and once a minute read the config
    /// back and rewrite only if it drifted (mode, level or durations). One short exchange per minute.
    private func housekeeping() {
        let saver = PowerState.shared.saver
        lock.lock(); defer { lock.unlock() }
        for i in boards.indices {
            if isSealed { return }
            let now = hostNow()
            if boards[i].hid.isRemoved {
                if boards[i].stale || boards[i].pendingRestore {
                    boards[i].stale = false
                    boards[i].pendingRestore = false
                    refreshAnyStaleLocked()
                }
                continue
            }
            if boards[i].pendingRestore {
                if wcond.withLock({ engaged }) {
                    boards[i].pendingRestore = false   // a newer engage supersedes the restore
                    refreshAnyStaleLocked()
                    continue
                }
                let activityAt = latestActivity(for: boards[i])
                let woke = activityAt > max(boards[i].staleAt, boards[i].wakeAttemptedAt)
                guard woke || now >= boards[i].nextRetryAt else { continue }
                if restoreBoardLocked(i, attempts: 1, timeout: 0.5, retryTimeouts: false) {
                    refreshAnyStaleLocked()
                } else {
                    boards[i].wakeAttemptedAt = hostNow()
                    boards[i].nextRetryAt = hostNow() + boards[i].retryDelay
                    boards[i].retryDelay = min(boards[i].retryDelay * 2, 30)
                    refreshAnyStaleLocked()
                }
                continue
            }
            guard boards[i].dirty || boards[i].stale, boards[i].wantLevel >= 0 else { continue }
            if boards[i].stale {
                let activityAt = latestActivity(for: boards[i])
                let woke = activityAt > max(boards[i].staleAt, boards[i].wakeAttemptedAt)
                guard woke || now >= boards[i].nextRetryAt else { continue }
                if woke {
                    logThrottled(key: "wake.\(boards[i].hid.name)", msg: "[logi] \(boards[i].hid.name): input seen while asleep; resending", interval: 5)
                }
                _ = sendEngagedLocked(i, level: boards[i].wantLevel, now: now)
                if boards[i].stale { boards[i].wakeAttemptedAt = hostNow() }
                continue
            }
            // On battery a quiet keyboard is checked less often instead of never.
            let quiet = saver && now - boards[i].lastChangeAt >= Self.quietAfter
            guard now - boards[i].lastVerify >= (quiet ? Self.quietVerifyInterval : Self.verifyInterval) else { continue }
            boards[i].lastVerify = now
            switch boards[i].hid.requestResult(feature: boards[i].feature, function: 0, timeout: 0.5) {
            case .success(let cfg) where cfg.count >= 12:
                let c = Array(cfg.prefix(12))
                let want = boards[i].wantLevel
                let durOK = boards[i].engagedDurations.map { Array(c[6..<12]) == $0 } ?? true
                if c[0] != 1 || Self.mode(of: c) != 3 || (want >= 0 && Int(c[5]) != want) || !durOK {
                    Log.write("[logi] \(boards[i].hid.name): drifted (live \(Self.hex(c)), want level \(want)); resent")
                    _ = sendEngagedLocked(i, level: boards[i].wantLevel, now: now)
                }
            case .success: break
            case .failure(let err):
                if case .timeout = err { markStaleLocked(i, now: hostNow()) }
                else if case .removed = err, boards.allSatisfy({ $0.hid.isRemoved }) { connBox.set(false) }
            }
        }
    }

    private func nextStaleRetryLocked() -> Double? {
        var earliest: Double?
        for b in boards where (b.stale || b.pendingRestore) && (b.wantLevel >= 0 || b.pendingRestore) && !b.hid.isRemoved {
            earliest = earliest.map { min($0, b.nextRetryAt) } ?? b.nextRetryAt
        }
        return earliest
    }

    private func setLevelResult(_ v: Float, epoch: Int? = nil) -> (ok: Bool, wrote: Bool, anyRemoved: Bool, error: HIDPPError?, stale: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isSealed { return (true, false, false, nil, true) }
        // A restore() that ran after the writer popped this target must not be undone by it.
        if let epoch, wcond.withLock({ restoreEpoch }) != epoch { return (true, false, false, nil, true) }
        guard !boards.isEmpty else { return (false, false, false, nil, false) }
        var ok = true
        var wrote = false
        var anyRemoved = false
        var lastErr: HIDPPError?

        for i in boards.indices {
            if boards[i].hid.isRemoved {
                anyRemoved = true
                ok = false
                lastErr = .removed
                continue
            }
            let level = Int((min(max(v, 0), 1) * Float(boards[i].levels - 1)).rounded())
            boards[i].wantLevel = level
            let now = hostNow()
            var wokeNow = false
            if boards[i].stale {
                let activityAt = latestActivity(for: boards[i])
                let woke = activityAt > max(boards[i].staleAt, boards[i].wakeAttemptedAt)
                if !woke && now < boards[i].nextRetryAt { continue }   // asleep: stay quiet until the backoff ends
                if woke {
                    logThrottled(key: "wake.\(boards[i].hid.name)", msg: "[logi] \(boards[i].hid.name): input seen while asleep; resending", interval: 5)
                }
                wokeNow = woke
            } else if level == boards[i].lastLevel && boards[i].engagedDurations != nil { continue }

            let sendErr = sendEngagedLocked(i, level: level, now: now)
            if wokeNow && boards[i].stale { boards[i].wakeAttemptedAt = hostNow() }
            if isSealed { return (true, false, false, nil, true) }
            if let err = sendErr {
                if case .timeout = err { continue }   // asleep, not broken: housekeeping retries
                ok = false
                if case .removed = err { anyRemoved = true }
                lastErr = err
                if boards[i].engagedDurations != nil {
                    logThrottled(key: "write.\(boards[i].hid.name).\(err)", msg: "[logi] \(boards[i].hid.name): setBacklightConfig failed (\(err))")
                } else {
                    logThrottled(key: "engage.\(boards[i].hid.name).\(err)", msg: "[logi] \(boards[i].hid.name): engage failed (\(err))")
                }
            } else {
                wrote = true
            }
        }
        return (ok, wrote, anyRemoved, lastErr, false)
    }

    /// Sets a manual level 0...1 on every found keyboard. Writes only when the level changes.
    @discardableResult func setLevel(_ v: Float) -> Bool {
        setLevelResult(v).ok
    }

    /// Puts each keyboard back to its saved original configuration.
    /// Synchronous restore for quit / signal paths: seals the writer, bounded wait for the board lock,
    /// short request timeouts, timeouts retried. A board that timed out is not retried by a second call.
    func restoreForQuit() {
        restore(attempts: 3, timeout: 0.4, lockWait: 1.25, retryTimeouts: true, seal: true)
    }

    func restore(attempts: Int = 2, timeout: Double = 0.5, lockWait: Double? = nil, retryTimeouts: Bool = true, seal: Bool = false) {
        wcond.lock()
        if seal { sealedBox.set(true) }
        else if sealedBox.get() { wcond.unlock(); return }   // the quit path owns the hand-back
        wantRelease = false
        target = -1
        resumePerceived = -1
        engaged = false
        restoreEpoch &+= 1
        wcond.signal()
        wcond.unlock()

        if let lockWait {
            guard lock.lock(before: Date(timeIntervalSinceNow: lockWait)) else {
                Log.write("[logi] restore: writer busy, could not take the board lock in \(lockWait) s")
                return
            }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        for i in boards.indices {
            boards[i].stale = false
            refreshAnyStaleLocked()
            guard boards[i].dirty else { boards[i].pendingRestore = false; continue }
            if seal && boards[i].quitFailed { continue }
            if !restoreBoardLocked(i, attempts: attempts, timeout: timeout, retryTimeouts: retryTimeouts, quit: seal) {
                // Stay dirty; housekeeping retries when the keyboard wakes.
                if !boards[i].pendingRestore {
                    boards[i].pendingRestore = true
                    boards[i].staleAt = hostNow()
                    boards[i].wakeAttemptedAt = 0
                    boards[i].retryDelay = 5
                    boards[i].nextRetryAt = hostNow() + 5
                }
                refreshAnyStaleLocked()
            }
        }
    }

    /// Caller holds `lock`. Writes the saved original back; true when the board is clean afterwards.
    private func restoreBoardLocked(_ i: Int, attempts: Int, timeout: Double, retryTimeouts: Bool, quit: Bool = false) -> Bool {
        guard boards[i].dirty else { boards[i].pendingRestore = false; return true }
        if boards[i].hid.isRemoved {
            boards[i].lastLevel = -1
            boards[i].dirty = false
            boards[i].pendingRestore = false
            return true
        }
        let targetCfg = boards[i].original ?? boards[i].baseConfig
        let p: [UInt8] = [targetCfg[0], targetCfg[1], 0xFF, targetCfg[5],
                          targetCfg[6], targetCfg[7], targetCfg[8], targetCfg[9], targetCfg[10], targetCfg[11]]
        var result = boards[i].hid.requestResult(feature: boards[i].feature, function: 1, params: p, timeout: timeout)
        var tries = 1
        while case .failure(let e) = result, tries < attempts, !e.isDisconnectLike || (retryTimeouts && e.isTimeout) {
            Thread.sleep(forTimeInterval: 0.1)
            result = boards[i].hid.requestResult(feature: boards[i].feature, function: 1, params: p, timeout: timeout)
            tries += 1
        }
        switch result {
        case .success:
            boards[i].lastLevel = -1
            boards[i].dirty = false
            boards[i].pendingRestore = false
            Self.persistEngaged(boards[i].hid, false)
            if boards[i].original != nil {
                Log.write("[logi] \(boards[i].hid.name): restored original config \(Self.hex(targetCfg))")
            } else {
                Log.write("[logi] \(boards[i].hid.name): restored base durations (no non-manual original saved)")
            }
            return true
        case .failure(let err):
            if quit && err.isTimeout { boards[i].quitFailed = true }
            logThrottled(key: "restore.\(boards[i].hid.name)", msg: "[logi] \(boards[i].hid.name): restore failed (\(err)); will retry when it wakes")
            return false
        }
    }

    // MARK: live output (GlowEngine)
    //
    // Each write is acknowledged by the keyboard about one Bluetooth round trip later (~24 ms on MX Keys),
    // so writes run on their own thread and only the newest target is sent. `leadSeconds` is the measured
    // round trip; GlowEngine renders the Logitech frame that much earlier so the keyboard lands on the beat.

    private let wcond = NSCondition()
    private var target: Float = -1          // perceived 0...1, < 0 = nothing pending
    private var resumePerceived: Float = -1 // last pushed level while active (re-sent on HID re-match)
    private var wantRelease = false
    private var restoreEpoch = 0
    private var writerStarted = false
    private var rttEWMA: Double = 0.024
    private var fails = 0
    private var lastScan: Double = 0
    private var nextDiscoverAt: Double = 0
    private var backoffSeconds: Double = LogitechBacklight.minBackoff
    private var lastWriteAt: Double = 0
    private var engaged = false
    private var scanning = false
    private var housekeepFlag = false

    private let logThrottleLock = NSLock()
    private var logTimestamps: [String: Double] = [:]

    private func logThrottled(key: String, msg: String, interval: Double = 10) {
        let now = hostNow()
        let shouldLog = logThrottleLock.withLock { () -> Bool in
            if let last = logTimestamps[key], now - last < interval { return false }
            logTimestamps[key] = now
            return true
        }
        if shouldLog { Log.write(msg) }
    }

    /// Measured Bluetooth round trip per write (seconds).
    /// Mirrors of `rttEWMA` / `!boards.isEmpty` so the glow tick never waits on the BLE I/O locks.
    private let rttBox = Locked<Double>(0.024)
    private let connBox = Locked<Bool>(false)
    var leadSeconds: Double { rttBox.get() }
    var isConnected: Bool { connBox.get() }

    /// Rescans in the background with exponential backoff while no keyboard is connected (hot-plug).
    func pollDiscover() {
        let now = hostNow()
        wcond.lock()
        guard !scanning, now >= nextDiscoverAt, now - lastScan >= Self.minBackoff else { wcond.unlock(); return }
        scanning = true
        lastScan = now
        wcond.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            _ = discoverIfNeeded()
            wcond.withLock { scanning = false }
        }
    }

    /// Latest wanted level (perceived 0...1). Never blocks.
    func push(_ perceived: Float) {
        wcond.lock()
        if sealedBox.get() { wcond.unlock(); return }
        let clamped = min(max(perceived, 0), 1)
        let wasIdle = target < 0 || wantRelease
        target = clamped
        resumePerceived = clamped
        wantRelease = false
        startWriterLocked()
        if wasIdle { wcond.signal() }
        wcond.unlock()
    }

    /// Hands the keyboard back to its own settings (after any pending write).
    func release() {
        wcond.lock()
        target = -1
        resumePerceived = -1
        wantRelease = true
        startWriterLocked()
        wcond.signal()
        wcond.unlock()
    }

    private func startWriterLocked() {
        guard !writerStarted else { return }
        writerStarted = true
        let t = Thread { [unowned self] in self.writerLoop() }
        t.name = "HapticGlow.logi-writer"; t.qualityOfService = .userInitiated; t.start()
    }

    private func writerLoop() {
        var lastHousekeepAt = hostNow()
        while true {
            wcond.lock()
            while target < 0 && !wantRelease {
                var due = housekeepFlag
                if !due {
                    var deadline = Double.greatestFiniteMagnitude
                    if engaged {
                        deadline = lastHousekeepAt + (PowerState.shared.saver ? 15 : 5)
                    }
                    if anyStale.get(), !sealedBox.get(), let staleRetry = nextRetryBox.get() {
                        deadline = min(deadline, staleRetry)
                    }
                    if deadline == Double.greatestFiniteMagnitude {
                        wcond.wait()
                        due = housekeepFlag
                    } else {
                        // Floor: a retry time already in the past must not turn this loop into a spin.
                        deadline = max(deadline, lastHousekeepAt + 0.05)
                        let wait = deadline - hostNow()
                        if wait <= 0.01 {
                            due = true
                        } else {
                            _ = wcond.wait(until: Date(timeIntervalSinceNow: wait))
                            due = housekeepFlag || hostNow() >= deadline - 0.01
                        }
                    }
                }
                if due {
                    housekeepFlag = false
                    lastHousekeepAt = hostNow()
                    wcond.unlock(); housekeeping(); wcond.lock()
                }
            }
            if wantRelease {
                target = -1; wantRelease = false
                let wasEngaged = engaged
                engaged = false
                wcond.unlock()
                _ = wasEngaged; restore()
                continue
            }

            // Cap write rate to what the BLE link comfortably sustains (~25-28 Hz) while coalescing newer targets.
            let minInterval = min(max(rttEWMA * 1.25, Self.minWriteFloor), 0.15)
            while target >= 0 && !wantRelease {
                let wait = (lastWriteAt + minInterval) - hostNow()
                if wait <= 0.001 { break }
                _ = wcond.wait(until: Date(timeIntervalSinceNow: wait))
            }
            if wantRelease {
                target = -1; wantRelease = false
                let wasEngaged = engaged
                engaged = false
                wcond.unlock()
                _ = wasEngaged; restore()
                continue
            }
            let v = target
            let epoch = restoreEpoch
            target = -1
            let keepDue = engaged && (housekeepFlag || hostNow() - lastHousekeepAt >= (PowerState.shared.saver ? 15 : 5))
            if keepDue {
                housekeepFlag = false
                lastHousekeepAt = hostNow()
            }
            wcond.unlock()

            if keepDue { housekeeping() }

            if !isConnected {
                let now = hostNow()
                let canScan = wcond.withLock { () -> Bool in
                    guard !scanning, now >= nextDiscoverAt, now - lastScan >= Self.minBackoff else { return false }
                    scanning = true
                    lastScan = now
                    return true
                }
                if canScan {
                    _ = discoverIfNeeded()
                    wcond.withLock { scanning = false }
                }
                if !isConnected { continue }
            }

            let t0 = hostNow()
            let res = setLevelResult(v, epoch: epoch)
            if res.stale { continue }
            let dt = hostNow() - t0

            if res.ok {
                wcond.lock()
                engaged = true
                fails = 0
                backoffSeconds = Self.minBackoff
                if res.wrote {
                    lastWriteAt = hostNow()
                    if dt > 0.003 { rttEWMA = rttEWMA * 0.9 + min(dt, 0.2) * 0.1; rttBox.set(rttEWMA) }
                }
                wcond.unlock()
            } else {
                var dropNow = res.anyRemoved
                wcond.lock()
                fails += 1
                lastWriteAt = hostNow() + 0.12
                if let err = res.error, err.isDisconnectLike {
                    if fails >= 2 { dropNow = true }
                } else if fails >= 3 {
                    dropNow = true
                }
                var waitSec = 0
                if dropNow {
                    let d = backoffSeconds
                    nextDiscoverAt = hostNow() + d
                    backoffSeconds = min(backoffSeconds * 2, Self.maxBackoff)
                    fails = 0
                    engaged = false
                    waitSec = Int(d)
                }
                wcond.unlock()

                if dropNow {
                    logThrottled(key: "disconnect", msg: "[logi] keyboard unreachable (\(res.error?.description ?? "unknown")); backing off \(waitSec)s before rescan")
                    discoverLock.lock()
                    restore(attempts: 1)   // best effort: put dirty boards back before dropping them
                    lock.withLock { closeCurrentBoardsLocked() }
                    discoverLock.unlock()
                }
            }
        }
    }

    static func hex(_ a: [UInt8]) -> String { a.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// `HapticGlow --logi-probe [--test]`: discovery report, optional level sweep, write-rate check,
    /// 25 s hold test (verifies light stays in manual mode and at level), then restore + readback.
    /// Output: ~/Library/Logs/HapticGlow/logi-probe.txt (the app is started through `open`).
    static func probe(test: Bool) -> Int32 {
        var out = ""
        func say(_ s: String) { out += s + "\n" }
        let lb = LogitechBacklight.shared
        let names = lb.discover(diag: { say("diag: \($0)") })
        say("keyboards with BACKLIGHT2: \(names) levels \(lb.levelCount)")
        for b in lb.lock.withLock({ lb.boards }) {
            let origHex = b.original.map(hex) ?? "none"
            let origMode = b.original.map { String(mode(of: $0)) } ?? "none"
            say("\(b.hid.name) (serial='\(b.hid.serial)'): feature \(b.feature), live \(hex(b.baseConfig)) mode \(mode(of: b.baseConfig)), savedOriginal \(origHex) mode \(origMode)")
        }
        var allPassed = true
        for b in lb.lock.withLock({ lb.boards }) {
            switch b.hid.requestResult(feature: b.feature, function: 0) {
            case .success(let cfg) where cfg.count >= 12:
                let c = Array(cfg.prefix(12))
                let dho = Int(u16LE(c, 6)), dhi = Int(u16LE(c, 8)), dpow = Int(u16LE(c, 10))
                say("fn0 now: \(hex(c)) mode=\(mode(of: c)) level=\(c[5])")
                say("raw durations: dho=\(dho) dhi=\(dhi) dpow=\(dpow) (Solaar settings_templates.py Backlight2Duration encodes 5s units: *5 on read -> \(dho * 5)s / \(dhi * 5)s / \(dpow * 5)s; if 1s units -> \(dho)s / \(dhi)s / \(dpow)s)")
                say("unit reasoning: Solaar caps UI at 600s and notes 'actual maximum is 2 hours' (7200s = 1440 = 0x05a0 in 5s units); stock 3/6/60 = 15s/30s/5m")
            case .success: say("fn0 now: short reply")
            case .failure(let err): say("fn0 now: FAIL (\(err)) (keyboard asleep? type on it and rerun)")
            }
            say("cached max duration: \(UserDefaults.standard.integer(forKey: maxDurKey(b.hid)))")
        }
        if test && !names.isEmpty {
            for b in lb.lock.withLock({ lb.boards }) {
                let base = b.original ?? b.baseConfig
                let manual = (base[1] & 0x07) | (0x03 << 3)
                for (label, d) in [("ffff(65535)", [0xFF, 0xFF] as [UInt8]), ("1c20(7200)", [0x20, 0x1C]), ("0e10(3600)", [0x10, 0x0E]), ("0780(1920)", [0x80, 0x07]), ("0708(1800)", [0x08, 0x07]), ("05a0(1440)", [0xA0, 0x05]), ("02d0(720)", [0xD0, 0x02]), ("0168(360)", [0x68, 0x01])] {
                    let p: [UInt8] = [1, manual, 0xFF, base[5], d[0], d[1], d[0], d[1], d[0], d[1]]
                    let res = b.hid.requestResult(feature: b.feature, function: 1, params: p)
                    switch res {
                    case .success:
                        let rb = b.hid.request(feature: b.feature, function: 0).map { hex(Array($0.prefix(12))) } ?? "?"
                        say("dur probe \(label): OK -> readback \(rb)")
                    case .failure(let err):
                        say("dur probe \(label): FAIL (\(err))")
                    }
                }
            }
            lb.lock.withLock { for j in lb.boards.indices { lb.boards[j].dirty = true } }  // sweep left manual durations
            let n = lb.levelCount
            for l in Array(0..<n) + Array((0..<n).reversed()) {
                let t = Date()
                let res = lb.setLevelResult(Float(l) / Float(max(n - 1, 1)))
                let errNote = res.error.map { " (\($0))" } ?? ""
                say(String(format: "level %d ok %@ %.1f ms%@", l, res.ok ? "yes" : "no", Date().timeIntervalSince(t) * 1000, errNote))
                if !res.ok { allPassed = false }
                Thread.sleep(forTimeInterval: 0.2)
            }
            for b in lb.lock.withLock({ lb.boards }) {
                if let d = b.engagedDurations {
                    let dho = Int(u16LE(d, 0)), dhi = Int(u16LE(d, 2)), dpow = Int(u16LE(d, 4))
                    say("\(b.hid.name): engaged durations dho=\(dho) (\(dho * 5)s) dhi=\(dhi) (\(dhi * 5)s) dpow=\(dpow) (\(dpow * 5)s), cachedMax=\(UserDefaults.standard.integer(forKey: maxDurKey(b.hid)))")
                }
            }
            let t0 = Date(); var okN = 0
            for i in 0..<40 {
                lb.lock.withLock { for j in lb.boards.indices { lb.boards[j].lastLevel = -1 } }
                if lb.setLevel(i % 2 == 0 ? 0.3 : 0.6) { okN += 1 }
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            say(String(format: "rate: %d/40 ok in %.0f ms (%.1f ms each)", okN, ms, ms / 40))

            // Hold a level for 25 s without typing (> 15 s dho) and verify config stays in manual mode at level.
            let holdNorm: Float = 5.0 / Float(max(n - 1, 1))
            let holdOk = lb.setLevel(holdNorm)
            let expectedLevels = lb.lock.withLock {
                lb.boards.map { b in Int((min(max(holdNorm, 0), 1) * Float(b.levels - 1)).rounded()) }
            }
            say("hold start ok=\(holdOk) expectedLevels=\(expectedLevels)")
            Thread.sleep(forTimeInterval: 25.0)
            for (idx, b) in lb.lock.withLock({ lb.boards }).enumerated() {
                switch b.hid.requestResult(feature: b.feature, function: 0) {
                case .success(let cfg):
                    let c = Array(cfg.prefix(12))
                    let m = mode(of: c)
                    let lvl = c.count > 5 ? Int(c[5]) : -1
                    let ok = c.count >= 12 && c[0] == 1 && m == 3 && lvl == expectedLevels[idx]
                    if !ok { allPassed = false }
                    say("after 25s hold \(b.hid.name): \(ok ? "PASS" : "FAIL") config \(hex(c)) mode=\(m) level=\(lvl)")
                case .failure(let err):
                    allPassed = false
                    say("after 25s hold \(b.hid.name): FAIL (\(err))")
                }
            }

            lb.restore(); say("restored")
            for b in lb.lock.withLock({ lb.boards }) {
                switch b.hid.requestResult(feature: b.feature, function: 0) {
                case .success(let cfg):
                    let c = Array(cfg.prefix(12))
                    let expected = b.original ?? b.baseConfig
                    let ok = c.count >= 12 && c[0] == expected[0] && c[1] == expected[1]
                        && (mode(of: expected) != 3 || c[5] == expected[5]) && c[6..<12] == expected[6..<12]  // level is ambient in auto
                    if !ok { allPassed = false }
                    say("after restore \(b.hid.name): \(ok ? "PASS" : "FAIL") config \(hex(c)) mode=\(mode(of: c)) level=\(c.count > 5 ? Int(c[5]) : -1)")
                case .failure(let err):
                    allPassed = false
                    say("after restore \(b.hid.name): FAIL (\(err))")
                }
            }
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HapticGlow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: dir.appendingPathComponent("logi-probe.txt"), atomically: true, encoding: .utf8)
        print(out, terminator: "")
        if names.isEmpty { return 1 }
        return allPassed ? 0 : 2
    }
}
