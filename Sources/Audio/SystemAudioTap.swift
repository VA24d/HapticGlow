// Core Audio Process Tap capture of the system output mix (no BlackHole, no mic).
// Ported from MagicKey (MIT, XiaoSong1223) AudioTap.swift / AudioActivity.swift: tap + private
// aggregate recipe, 10 s IOProc-creation timeout, strict teardown order, device-change rebuild,
// watchdog separating "nothing playing" from "tap broken".
import Foundation
import CoreAudio
import AudioToolbox

private func gAddr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func defaultOutputDevice() -> AudioObjectID {
    var addr = gAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return st == noErr ? dev : AudioObjectID(kAudioObjectUnknown)
}

private func deviceString(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = gAddr(sel)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
    guard st == noErr, let c = cf else { return nil }
    return c.takeRetainedValue() as String
}

private func defaultOutputUID() -> String? {
    let dev = defaultOutputDevice()
    guard dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
    return deviceString(dev, kAudioDevicePropertyDeviceUID)
}

/// When the default output is a Multi-Output (aggregate) device, returns its main subdevice UID.
private func defaultOutputMainSubDeviceUID() -> String? {
    let dev = defaultOutputDevice()
    guard dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
    return deviceString(dev, kAudioAggregateDevicePropertyMainSubDevice)
        ?? deviceString(dev, kAudioDevicePropertyDeviceUID)
}

/// Is anything (any process) running IO on the default output device right now?
/// True when some process other than HapticGlow is playing audio. The tap excludes our own process,
/// and the key-sound engine keeps the output device running, so "device running somewhere" alone
/// would make the watchdog treat our own idle output as a stalled tap and rebuild it in a loop.
private func outputIsRunning() -> Bool {
    let dev = defaultOutputDevice()
    guard dev != AudioObjectID(kAudioObjectUnknown) else { return false }
    var addr = gAddr(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr, v != 0 else { return false }
    guard let own = ownProcessObject() else { return true }

    var listAddr = gAddr(kAudioHardwarePropertyProcessObjectList)
    var listSize: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &listSize) == noErr, listSize > 0 else { return true }
    var procs = [AudioObjectID](repeating: 0, count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &listSize, &procs) == noErr else { return true }
    var runAddr = gAddr(kAudioProcessPropertyIsRunningOutput)
    for p in procs where p != own {
        var r: UInt32 = 0
        var rs = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(p, &runAddr, 0, nil, &rs, &r) == noErr, r != 0 { return true }
    }
    return false
}

/// Our own process's audio object (exists only once we have touched Core Audio output), or nil.
private func ownProcessObject() -> AudioObjectID? {
    var addr = gAddr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = getpid()
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                        UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    return (st == noErr && obj != AudioObjectID(kAudioObjectUnknown)) ? obj : nil
}

/// Counters written by the IO thread (single writer, no locks) and read by the watchdog.
private final class TapStats: @unchecked Sendable {
    var callbacks: UInt64 = 0
    var peakBits: UInt32 = 0
    /// Consecutive samples of exact digital silence (nothing but us is playing). Once this passes ~0.6 s the
    /// IO thread stops feeding the analyzer; the first non-silent buffer resumes it at once.
    var quietSamples: Int = 0
}

private final class TapResources: @unchecked Sendable {
    let tapID: AudioObjectID
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var started = false
    private let lock = NSLock()
    private var destroyed = false
    init(tapID: AudioObjectID) { self.tapID = tapID }

    /// Idempotent. Order matters: stop IO, destroy IOProc, destroy aggregate, destroy tap.
    func destroy() {
        lock.lock()
        guard !destroyed else { lock.unlock(); return }
        destroyed = true
        let agg = aggregateID, proc = procID, was = started
        procID = nil; started = false
        lock.unlock()
        if agg != AudioObjectID(kAudioObjectUnknown) {
            if let proc {
                if was { _ = AudioDeviceStop(agg, proc) }
                _ = AudioDeviceDestroyIOProcID(agg, proc)
            }
            _ = AudioHardwareDestroyAggregateDevice(agg)
        }
        _ = AudioHardwareDestroyProcessTap(tapID)
    }
}

private final class IOProcHandoff: @unchecked Sendable {
    let lock = NSLock()
    var status: OSStatus = kAudioHardwareUnspecifiedError
    var procID: AudioDeviceIOProcID?
    var abandoned = false
}

final class SystemAudioTap: @unchecked Sendable {
    static let shared = SystemAudioTap()

    /// Realtime sink: (mono samples, frameCount, sampleRate). Called on the CoreAudio IO thread.
    /// Set once before start(); the IO thread uses a snapshot taken at start().
    var sink: ((UnsafePointer<Float>, Int, Double) -> Void)?

    /// Called on the main queue whenever `state` changes.
    var onStateChange: ((AudioInputState) -> Void)?

    var state: AudioInputState { lock.withLock { _state } }
    var callbackRate: Double { lock.withLock { _rate } }
    var sampleRate: Double { lock.withLock { _sampleRate } }
    /// Peak |sample| seen since the last call (diagnostics; resets on read).
    func takePeak() -> Float {
        let b = stats.peakBits; stats.peakBits = 0
        return Float(bitPattern: b)
    }

    private let lock = UnfairLock()
    private var _state: AudioInputState = .inactive
    private var _rate: Double = 0
    private var _sampleRate: Double = 48000
    private let stats = TapStats()

    // Everything below is touched only on setupQueue.
    private let setupQueue = DispatchQueue(label: "hapticglow.audiotap.setup", qos: .utility)
    private var desired = false
    private var resources: TapResources?
    private var watchdog: DispatchSourceTimer?
    private var listener: AudioObjectPropertyListenerBlock?
    private var rebuildGen: UInt64 = 0
    private var recoverGen: UInt64 = 0
    private var recoverStep = 0
    private let setupTimeout: TimeInterval = 10
    private var everFlowed = false
    private var lastCount: UInt64 = 0
    private var lastTick: Double = 0
    private var stuckTicks = 0
    private var preflightGranted = false
    private var rebuildAttempts = 0
    private var excludedSelf = false
    private var excludedObject = AudioObjectID(kAudioObjectUnknown)
    private var powerObserver: NSObjectProtocol?

    init() {
        // Battery / Low Power Mode changes the watchdog's timer leeway.
        powerObserver = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: nil) { [weak self] _ in
            self?.setupQueue.async { if self?.watchdog != nil { self?.startWatchdog() } }
        }
    }

    /// Asks the tap to re-check that it still excludes our own process object. The key-sound engine calls this
    /// after restarting its audio engine, because a new engine can come with a new process object.
    func recheckExclusion() {
        setupQueue.async { [self] in
            guard desired, resources != nil else { return }
            _ = rebuildIfExclusionStale()
        }
    }

    // MARK: permission
    //
    // System Audio Recording is the TCC service kTCCServiceAudioCapture. There is no public preflight API,
    // so (like insidegui/AudioCap) we use the TCC SPI: TCCAccessPreflight gives the real answer for this
    // exact code signature, and TCCAccessRequest shows the system prompt. Without this the only signal is
    // "output is playing but the tap delivers nothing", which cannot tell a stale grant from silence.

    enum Permission: String, Sendable { case granted, denied, unknown }

    private static let tccHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)
    private static let tccService = "kTCCServiceAudioCapture" as CFString

    static var permission: Permission {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return .unknown }
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        switch unsafeBitCast(sym, to: Preflight.self)(tccService, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the macOS "record system audio" prompt when the status is undetermined. Calls back on any thread.
    static func requestPermission(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else { done(false); return }
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        unsafeBitCast(sym, to: Request.self)(tccService, nil) { ok in done(ok) }
    }

    func start() {
        guard #available(macOS 14.2, *) else { setState(.unsupported); return }
        setupQueue.async { [self] in
            guard !desired else { return }
            desired = true
            let p = Self.permission
            Log.write("[tap] permission preflight: \(p.rawValue)")
            switch p {
            case .granted:
                preflightGranted = true; rebuildAttempts = 0
                startBuild()
            case .denied:
                // A stale grant (app re-signed) or a refusal. The toggle in System Settings must be
                // removed and re-added; we retry on app activation (AppModel.retryCaptureIfNeeded).
                setState(.needsPermission)
            case .unknown:
                setState(.starting)
                Self.requestPermission { [weak self] ok in
                    Log.write("[tap] permission request: \(ok ? "granted" : "refused")")
                    guard let self else { return }
                    self.setupQueue.async {
                        guard self.desired, self.resources == nil else { return }
                        if ok { self.preflightGranted = true; self.startBuild() } else { self.setState(.needsPermission) }
                    }
                }
            }
        }
    }

    private func startBuild() {
        installListener()
        if !build(trigger: "start") { desired = false; removeListener() }
    }

    /// Non-blocking: teardown runs on the setup queue.
    func stop() { setupQueue.async { [self] in teardown() } }

    /// Quit path: waits briefly so teardown usually completes; never blocks the caller for long.
    func shutdown() {
        let done = DispatchSemaphore(value: 0)
        setupQueue.async { [self] in teardown(); done.signal() }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func teardown() {
        desired = false
        recoverGen &+= 1; recoverStep = 0
        removeListener()
        stopWatchdog()
        resources?.destroy(); resources = nil
        lock.withLock { _rate = 0 }
        setState(.inactive)
    }

    /// After a failed internal rebuild: retry with backoff (2, 5, 15, then 30 s) while still wanted.
    /// Permission failures are left to the app-activation retry.
    private func scheduleRecovery() {
        guard desired, case .failed = state else { return }
        recoverGen &+= 1
        let g = recoverGen
        let delays: [Double] = [2, 5, 15, 30]
        let d = delays[min(recoverStep, delays.count - 1)]
        recoverStep += 1
        setupQueue.asyncAfter(deadline: .now() + d) { [weak self] in
            guard let self, self.desired, self.recoverGen == g, self.resources == nil else { return }
            self.stopWatchdog()
            if !self.build(trigger: "retry") { self.scheduleRecovery() }
        }
    }

    // MARK: state

    private func setState(_ s: AudioInputState) {
        let changed: Bool = lock.withLock {
            if _state == s { return false }
            _state = s; return true
        }
        guard changed else { return }
        Log.write("[tap] state \(s)")
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }

    private func fail(_ msg: String, timedOut: Bool = false, permission: Bool = false) -> Bool {
        Log.write("[tap] \(msg)")
        resources?.destroy(); resources = nil
        stopWatchdog()
        setState(permission ? .needsPermission : .failed(msg))
        return false
    }

    // MARK: build

    private func build(trigger: String) -> Bool {
        setState(.starting)
        stats.callbacks = 0; stats.peakBits = 0; stats.quietSamples = 0
        everFlowed = false; lastCount = 0; stuckTicks = 0
        guard let outUID = defaultOutputUID() else { return fail("No output device") }
        guard #available(macOS 14.2, *) else { setState(.unsupported); return false }

        let exclude: [AudioObjectID] = ownProcessObject().map { [$0] } ?? []
        excludedSelf = !exclude.isEmpty
        excludedObject = exclude.first ?? AudioObjectID(kAudioObjectUnknown)
        Log.write("[tap] build (\(trigger)): own audio \(excludedSelf ? "excluded (process object \(excludedObject))" : "not excluded yet (no process object; rebuilds once HapticGlow plays audio)"), output \(outUID)")
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: exclude)
        desc.name = "HapticGlow"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let ts = AudioHardwareCreateProcessTap(desc, &tapID)
        guard ts == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            return fail("Audio tap failed (\(ts)). System Audio Recording permission is likely missing.",
                        permission: true)
        }
        let res = TapResources(tapID: tapID)
        resources = res

        var asbd = AudioStreamBasicDescription()
        var asz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = gAddr(kAudioTapPropertyFormat)
        if AudioObjectGetPropertyData(tapID, &fa, 0, nil, &asz, &asbd) == noErr {
            let ok = asbd.mFormatID == kAudioFormatLinearPCM
                && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
            guard ok, asbd.mChannelsPerFrame == 1 else { return fail("Unexpected tap stream format") }
            if asbd.mSampleRate > 0 { lock.withLock { _sampleRate = asbd.mSampleRate } }
        }
        let sr = sampleRate

        var ua = gAddr(kAudioTapPropertyUID)
        var tapUID: Unmanaged<CFString>?
        var usz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let us = withUnsafeMutablePointer(to: &tapUID) { AudioObjectGetPropertyData(tapID, &ua, 0, nil, &usz, $0) }
        guard us == noErr, let tu = tapUID else { return fail("Tap UID unavailable (\(us))") }
        let tapUIDStr = tu.takeRetainedValue() as String

        func makeAggDesc(mainUID: String) -> [String: Any] {
            [
                kAudioAggregateDeviceNameKey: "HapticGlow Audio Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: mainUID,
                kAudioAggregateDeviceSubDeviceListKey: [Any](),
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUIDStr,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        var as_ = AudioHardwareCreateAggregateDevice(makeAggDesc(mainUID: outUID) as CFDictionary, &aggID)
        if (as_ != noErr || aggID == AudioObjectID(kAudioObjectUnknown)),
           let subUID = defaultOutputMainSubDeviceUID(), subUID != outUID {
            aggID = AudioObjectID(kAudioObjectUnknown)
            as_ = AudioHardwareCreateAggregateDevice(makeAggDesc(mainUID: subUID) as CFDictionary, &aggID)
        }
        guard as_ == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            return fail("Aggregate device failed (\(as_))")
        }
        res.aggregateID = aggID

        let snapshot = sink
        let stats = self.stats
        let block: AudioDeviceIOBlock = { _, inData, _, _, _ in
            let abl = inData.pointee
            guard abl.mNumberBuffers > 0, let raw = abl.mBuffers.mData else { return }
            let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { return }
            let p = raw.assumingMemoryBound(to: Float.self)
            var pk: Float = 0
            for i in 0..<n { let a = abs(p[i]); if a > pk { pk = a } }
            if pk.bitPattern > stats.peakBits { stats.peakBits = pk.bitPattern }  // non-negative floats order as bits
            stats.callbacks &+= 1
            // Nothing else is playing (our own audio is excluded, so the mix is exact zeros): skip the analysis
            // after 0.6 s. The first non-silent buffer re-enables it with no added latency.
            if pk < 1e-7 {
                stats.quietSamples = stats.quietSamples > Int.max / 2 ? stats.quietSamples : stats.quietSamples + n
                if Double(stats.quietSamples) > sr * 0.6 { return }
            } else { stats.quietSamples = 0 }
            snapshot?(p, n, sr)
        }

        let hand = IOProcHandoff()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var pid: AudioDeviceIOProcID?
            let st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil, block)
            hand.lock.lock()
            if hand.abandoned {
                hand.lock.unlock()
                if let pid { _ = AudioDeviceDestroyIOProcID(aggID, pid) }
                return
            }
            hand.status = st; hand.procID = pid
            hand.lock.unlock()
            sem.signal()
        }
        if sem.wait(timeout: .now() + setupTimeout) == .timedOut {
            hand.lock.lock()
            res.procID = hand.procID
            hand.abandoned = true
            hand.lock.unlock()
            return fail("Audio setup timed out. System Audio Recording permission is likely missing.",
                        timedOut: true, permission: true)
        }
        guard hand.status == noErr, let procID = hand.procID else {
            return fail("IOProc creation failed (\(hand.status))")
        }
        res.procID = procID
        requestSmallBuffer(aggID)
        let ss = AudioDeviceStart(aggID, procID)
        guard ss == noErr else { return fail("AudioDeviceStart failed (\(ss))") }
        res.started = true

        lastTick = hostNow()
        evaluate()
        startWatchdog()
        return true
    }

    /// Asks the aggregate for a 128-frame IO buffer (lower capture latency). The device may clamp or refuse;
    /// the size actually in effect is logged once per build.
    private func requestSmallBuffer(_ dev: AudioObjectID) {
        var a = gAddr(kAudioDevicePropertyBufferFrameSize)
        var want: UInt32 = 128
        let st = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &want)
        var got: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        let gs = AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &got)
        Log.write("[tap] IO buffer frames: requested 128, set status \(st), actual \(gs == noErr ? String(got) : "unknown")")
    }

    // MARK: watchdog

    /// Rebuilds the tap when our process object exists but is not the one being excluded (first audio output
    /// after the tap was built, or a new object after the key-sound engine restarted). Returns true if rebuilt.
    private func rebuildIfExclusionStale() -> Bool {
        guard let own = ownProcessObject(), !excludedSelf || own != excludedObject else { return false }
        stopWatchdog()
        resources?.destroy(); resources = nil
        if !build(trigger: excludedSelf ? "own process object changed" : "exclude self") { scheduleRecovery() }
        return true
    }

    /// Runs on setupQueue every second.
    private func evaluate() {
        // Our process object only exists once we have touched Core Audio output (key sounds). If the tap
        // was built before that, our own clicks would feed the analyzer: rebuild once it can be excluded.
        if desired, rebuildIfExclusionStale() { return }
        let now = hostNow()
        let c = stats.callbacks
        let dt = max(0.001, now - lastTick)
        let rate = Double(c &- lastCount) / dt
        lock.withLock { _rate = rate }
        let flowed = c != lastCount
        lastCount = c; lastTick = now
        if flowed {
            everFlowed = true; stuckTicks = 0; rebuildAttempts = 0; recoverStep = 0
            setState(.active)
        } else if !outputIsRunning() {
            stuckTicks = 0
            setState(.idleNoAudio)
        } else {
            stuckTicks += 1
            if preflightGranted, stuckTicks >= min(30, 3 << min(4, rebuildAttempts)) {
                // Permission is granted, so silence is a stalled tap, not a permission problem: rebuild with backoff.
                Log.write("[tap] no callbacks while output runs (attempt \(rebuildAttempts + 1)); rebuilding")
                rebuildAttempts += 1; stuckTicks = 0
                setState(.stalled)
                stopWatchdog()
                resources?.destroy(); resources = nil
                if !build(trigger: "stalled") { scheduleRecovery() }
            } else if !preflightGranted, stuckTicks >= 3 {
                // Output is playing but we never got a callback and TCC did not report a grant.
                setState(everFlowed ? .stalled : .needsPermission)
            } else if state == .starting || state == .idleNoAudio {
                // give it a moment; leave state unchanged otherwise
                if state == .idleNoAudio { setState(.starting) }
            }
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let t = DispatchSource.makeTimerSource(queue: setupQueue)
        // The watchdog is not time critical: on battery let the system coalesce it with other wakeups.
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(PowerState.shared.saver ? 900 : 400))
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        watchdog = t
    }

    private func stopWatchdog() { watchdog?.cancel(); watchdog = nil }

    // MARK: default output device changes

    private func installListener() {
        guard listener == nil else { return }
        var addr = gAddr(kAudioHardwarePropertyDefaultOutputDevice)
        let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.rebuildGen &+= 1
            let g = self.rebuildGen
            self.setupQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.rebuildGen == g, self.desired else { return }
                self.stopWatchdog()
                self.resources?.destroy(); self.resources = nil
                if !self.build(trigger: "device change") { self.scheduleRecovery() }
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, setupQueue, blk) == noErr {
            listener = blk
        }
    }

    private func removeListener() {
        guard let blk = listener else { return }
        listener = nil
        var addr = gAddr(kAudioHardwarePropertyDefaultOutputDevice)
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, setupQueue, blk)
    }
}
