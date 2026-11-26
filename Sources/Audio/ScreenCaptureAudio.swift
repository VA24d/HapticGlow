// ScreenCaptureKit system-audio capture: the literal screen-recording API (SCStream audio).
// Public API mirrors SystemAudioTap so AppModel can switch backends (protocol AudioCapture).
// Audio-only use: a 2x2 px, 1 fps video stream is requested (SCK needs a display filter) and dropped.
import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AudioToolbox

final class ScreenCaptureAudio: NSObject, @unchecked Sendable {
    static let shared = ScreenCaptureAudio()

    /// Realtime sink: (mono samples, frameCount, sampleRate), called on the SCStream sample queue.
    var sink: ((UnsafePointer<Float>, Int, Double) -> Void)?
    /// Called on the main queue whenever `state` changes.
    var onStateChange: ((AudioInputState) -> Void)?

    var state: AudioInputState { lock.withLock { _state } }
    var callbackRate: Double { lock.withLock { _rate } }
    var sampleRate: Double { 48000 }

    // MARK: permission (additive API)

    /// Screen Recording (TCC) status without prompting.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt the first time; returns current status.
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: state

    private let lock = UnfairLock()
    private var _state: AudioInputState = .inactive
    private var _rate: Double = 0

    // Control state: touched only on `ctl`.
    private let ctl = DispatchQueue(label: "hapticglow.sck.ctl", qos: .utility)
    private var desired = false
    private var gen: UInt64 = 0
    private var stream: SCStream?
    private var watchdog: DispatchSourceTimer?
    private var retryDelay: Double = 1
    private var lastCount: UInt64 = 0
    private var lastTick: Double = 0
    private var everFlowed = false

    // Sample queue state: written only on `sampleQueue`, read (benignly racy) by the watchdog.
    private let sampleQueue = DispatchQueue(label: "hapticglow.sck.audio", qos: .userInteractive)
    private var callbacks: UInt64 = 0
    private var loudCallbacks: UInt64 = 0
    private var quietFrames = 0
    private var mono = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
    private var monoCap = 16384
    private var abl = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size + 7 * MemoryLayout<AudioBuffer>.size,
                                                       alignment: 16)
    private let ablSize = MemoryLayout<AudioBufferList>.size + 7 * MemoryLayout<AudioBuffer>.size
    private var sinkSnap: ((UnsafePointer<Float>, Int, Double) -> Void)?

    private let silenceThreshold: Float = 1e-6
    private var powerObserver: NSObjectProtocol?

    override init() {
        super.init()
        powerObserver = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: nil) { [weak self] _ in
            self?.ctl.async { if self?.watchdog != nil { self?.startWatchdog() } }
        }
    }

    // MARK: start / stop

    func start() {
        ctl.async { [self] in
            guard !desired else { return }
            desired = true
            retryDelay = 1
            launch()
        }
    }

    /// Non-blocking: teardown runs on the control queue.
    func stop() { ctl.async { [self] in teardown(nil) } }

    /// Quit path: waits briefly so teardown usually completes.
    func shutdown() {
        let done = DispatchSemaphore(value: 0)
        ctl.async { [self] in teardown(done) }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func teardown(_ done: DispatchSemaphore?) {
        desired = false
        gen &+= 1
        stopWatchdog()
        let s = stream; stream = nil
        lock.withLock { _rate = 0 }
        setState(.inactive)
        if let s { s.stopCapture { _ in done?.signal() } } else { done?.signal() }
    }

    private func setState(_ s: AudioInputState) {
        let changed: Bool = lock.withLock {
            if _state == s { return false }
            _state = s; return true
        }
        guard changed else { return }
        Log.write("[sck] state \(s)")
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }

    // MARK: stream lifecycle (on ctl)

    private func launch() {
        guard desired else { return }
        gen &+= 1
        let g = gen
        guard CGPreflightScreenCaptureAccess() else {
            // Already waiting on permission: stay quiet; app activation retries.
            if lock.withLock({ _state }) != .needsPermission {
                setState(.starting)
                setState(.needsPermission)
            }
            return
        }
        setState(.starting)
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.current
                guard let self else { return }
                self.ctl.async { self.attach(content, g) }
            } catch {
                self?.ctl.async { self?.handleFailure(error, g) }
            }
        }
    }

    private func attach(_ content: SCShareableContent, _ g: UInt64) {
        guard desired, g == gen else { return }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            setState(.failed("No display for capture")); scheduleRetry(g, delay: retryDelay); return
        }
        let me = getpid()
        let ours = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3
        cfg.showsCursor = false
        Log.write("[sck] build: own audio excluded (excludesCurrentProcessAudio=\(cfg.excludesCurrentProcessAudio), \(ours.count) own app(s) filtered)")

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue) }
        catch { handleFailure(error, g); return }
        callbacks = 0; loudCallbacks = 0; lastCount = 0; everFlowed = false
        sampleQueue.sync { sinkSnap = sink }
        stream = s
        s.startCapture { [weak self] err in
            self?.ctl.async {
                guard let self, self.desired, g == self.gen else { return }
                if let err { self.handleFailure(err, g); return }
                self.retryDelay = 1
                self.lastTick = hostNow()
                self.startWatchdog()
            }
        }
    }

    private func handleFailure(_ error: Error, _ g: UInt64) {
        guard desired, g == gen else { return }
        stopWatchdog()
        let old = stream; stream = nil
        old?.stopCapture { _ in }
        lock.withLock { _rate = 0 }
        let ns = error as NSError
        // SCStreamError.userDeclined == -3801; also any TCC-flavoured failure.
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue
            || !CGPreflightScreenCaptureAccess() {
            setState(.needsPermission)
        } else {
            setState(.failed("Screen audio failed: \(ns.localizedDescription)"))
            scheduleRetry(g, delay: retryDelay)
            retryDelay = min(retryDelay * 2, 8)
        }
    }

    private func scheduleRetry(_ g: UInt64, delay: Double) {
        ctl.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.desired, g == self.gen else { return }
            self.launch()
        }
    }

    // MARK: watchdog (on ctl, 1 Hz)

    private func startWatchdog() {
        stopWatchdog()
        let t = DispatchSource.makeTimerSource(queue: ctl)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(PowerState.shared.saver ? 900 : 400))
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        watchdog = t
    }
    private func stopWatchdog() { watchdog?.cancel(); watchdog = nil }

    private func evaluate() {
        guard desired else { return }
        let now = hostNow()
        let c = callbacks, loud = loudCallbacks
        let dt = max(0.001, now - lastTick)
        lock.withLock { _rate = Double(c &- lastCount) / dt }
        let hadBuffers = c != lastCount
        lastCount = c; lastTick = now
        let wasLoud = loud != lastLoud
        lastLoud = loud
        if wasLoud { everFlowed = true; setState(.active) }
        else if hadBuffers { setState(.idleNoAudio) }          // silent buffers
        else { setState(.idleNoAudio) }                          // stream runs, nothing delivered
    }
    private var lastLoud: UInt64 = 0

    // MARK: realtime path (on sampleQueue)

    private func process(_ sb: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sb), CMSampleBufferGetNumSamples(sb) > 0,
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32 else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        if frames > monoCap {
            mono.deallocate()
            monoCap = frames; mono = .allocate(capacity: frames)
        }
        var sizeNeeded = 0
        var block: CMBlockBuffer?
        let list = abl.bindMemory(to: AudioBufferList.self, capacity: 1)
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: list, bufferListSize: ablSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard st == noErr else { return }
        let nb = Int(list.pointee.mNumberBuffers)
        guard nb > 0 else { return }
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        var peak: Float = 0
        withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
            let bufs = UnsafeBufferPointer(start: first, count: nb)
            if interleaved || nb == 1 {
                let ch = max(1, Int(interleaved ? asbd.mChannelsPerFrame : 1))
                guard let d = bufs[0].mData else { return }
                let p = d.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(bufs[0].mDataByteSize) / (4 * ch))
                for i in 0..<n {
                    var sum: Float = 0
                    for c in 0..<ch { sum += p[i * ch + c] }
                    let v = sum / Float(ch)
                    mono[i] = v
                    let a = abs(v); if a > peak { peak = a }
                }
                if n < frames { for i in n..<frames { mono[i] = 0 } }
            } else {
                guard let l = bufs[0].mData, let r = bufs[1].mData else { return }
                let lp = l.assumingMemoryBound(to: Float.self), rp = r.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(min(bufs[0].mDataByteSize, bufs[1].mDataByteSize)) / 4)
                for i in 0..<n {
                    let v = (lp[i] + rp[i]) * 0.5
                    mono[i] = v
                    let a = abs(v); if a > peak { peak = a }
                }
                if n < frames { for i in n..<frames { mono[i] = 0 } }
            }
        }
        callbacks &+= 1
        if peak > silenceThreshold { loudCallbacks &+= 1 }
        let sr = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        // Silent output (nothing playing): stop analysing after 0.6 s; the first sound resumes it at once.
        if peak < 1e-7 {
            quietFrames = quietFrames > Int.max / 2 ? quietFrames : quietFrames + frames
            if Double(quietFrames) > sr * 0.6 { _ = block; return }
        } else { quietFrames = 0 }
        sinkSnap?(mono, frames, sr)
        _ = block
    }
}

extension ScreenCaptureAudio: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        process(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ctl.async { [self] in
            guard desired, self.stream === stream else { return }
            handleFailure(error, gen)
        }
    }
}
