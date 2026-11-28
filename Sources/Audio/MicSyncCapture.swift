// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// MicSyncCapture: the two recorders behind "Measure with microphone".
//  - MicSyncTapRing keeps a copy of what the process tap captures while a measurement runs. The tap's realtime
//    callback only memcpy's into a preallocated ring and stores a timestamp: no lock, no allocation.
//  - MicRecorder records the built-in microphone through an AUHAL input unit bound to that device. The system's
//    default input device is never touched, and nothing is played.
// Both stamp their buffers with the Mach host clock so the controller can lay them on one timeline.
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Host clock helpers (mach_absolute_time ticks to seconds).
enum HostClock {
    private static let ratio: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) * 1e-9
    }()
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * ratio }
    static var now: UInt64 { mach_absolute_time() }
}

/// Lock-free single-producer ring fed by the tap's realtime sink. Armed and read from other threads.
final class MicSyncTapRing: @unchecked Sendable {
    static let shared = MicSyncTapRing()
    static let maxRate = 96000.0
    static let seconds = 14.0
    private static let stampCap = 8192

    private let armed = Atomic<Bool>(false)
    private let pos = Atomic<Int>(0)          // samples written since launch (monotonic)
    private let stamps = Atomic<Int>(0)       // stamps written since launch (monotonic)
    private let rateBits = Atomic<UInt64>(0)
    private var buf: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private var stampEnd: UnsafeMutablePointer<Int>?
    private var stampHost: UnsafeMutablePointer<UInt64>?

    struct Slice { var samples: [Float]; var rate: Double; var startSeconds: Double }

    /// Main thread. Allocates the ring on first use; false when the tap is not delivering audio at a usable rate.
    func arm() -> Bool {
        if buf == nil {
            capacity = Int(Self.maxRate * Self.seconds)
            buf = .allocate(capacity: capacity); buf!.initialize(repeating: 0, count: capacity)
            stampEnd = .allocate(capacity: Self.stampCap); stampEnd!.initialize(repeating: 0, count: Self.stampCap)
            stampHost = .allocate(capacity: Self.stampCap); stampHost!.initialize(repeating: 0, count: Self.stampCap)
        }
        rateBits.store(0, ordering: .relaxed)
        armed.store(true, ordering: .releasing)
        return true
    }
    /// Index of the next sample to be written. Read right after `arm()` to mark where a recording begins.
    var position: Int { pos.load(ordering: .acquiring) }
    var stampMark: Int { stamps.load(ordering: .acquiring) }
    func disarm() { armed.store(false, ordering: .releasing) }
    var isReceiving: Bool { rateBits.load(ordering: .relaxed) != 0 }

    /// Realtime. Called from the tap's IO thread with mono samples.
    func push(_ p: UnsafePointer<Float>, _ n: Int, _ rate: Double) {
        guard armed.load(ordering: .acquiring), let buf, let stampEnd, let stampHost, n > 0, n < capacity,
              rate <= Self.maxRate else { return }
        let host = HostClock.now
        let w = pos.load(ordering: .relaxed)
        let i = w % capacity
        let first = min(n, capacity - i)
        memcpy(buf + i, p, first * MemoryLayout<Float>.size)
        if first < n { memcpy(buf, p + first, (n - first) * MemoryLayout<Float>.size) }
        let s = stamps.load(ordering: .relaxed)
        stampEnd[s % Self.stampCap] = w + n
        stampHost[s % Self.stampCap] = host
        rateBits.store(rate.bitPattern, ordering: .relaxed)
        stamps.store(s + 1, ordering: .releasing)
        pos.store(w + n, ordering: .releasing)
    }

    /// Copies samples [from, to) and dates the first one on the host clock (seconds). Call after `disarm()`.
    func slice(from: Int, to: Int, stampsFrom: Int) -> Slice? {
        guard let buf, let stampEnd, let stampHost, to > from, to - from < capacity - Int(Self.maxRate / 2) else { return nil }
        let rate = Double(bitPattern: rateBits.load(ordering: .relaxed))
        guard rate > 0 else { return nil }
        var out = [Float](repeating: 0, count: to - from)
        for j in 0..<(to - from) { out[j] = buf[(from + j) % capacity] }
        // Each callback ended at stampEnd samples at host time stampHost. Median removes scheduling jitter.
        let sCount = stamps.load(ordering: .acquiring)
        var offs: [Double] = []
        for s in max(stampsFrom, sCount - Self.stampCap + 1)..<sCount {
            let e = stampEnd[s % Self.stampCap]
            if e > from && e <= to { offs.append(HostClock.seconds(stampHost[s % Self.stampCap]) - Double(e - from) / rate) }
        }
        guard offs.count >= 8 else { return nil }
        offs.sort()
        return Slice(samples: out, rate: rate, startSeconds: offs[offs.count / 2])
    }
}

/// Built-in microphone recorder (AUHAL input unit). One recording of a fixed length; reuse by creating a new one.
final class MicRecorder: @unchecked Sendable {
    enum StartError: Error { case noDevice, unit(OSStatus), rate }

    let deviceID: AudioObjectID
    private(set) var rate: Double = 0
    private var unit: AudioUnit?
    private var buf: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private let written = Atomic<Int>(0)
    private var stampStart = [Int](repeating: 0, count: 2048)
    private var stampHost = [UInt64](repeating: 0, count: 2048)
    private let stampCount = Atomic<Int>(0)
    private let failed = Atomic<Int32>(0)

    struct Recording { var samples: [Float]; var rate: Double; var startSeconds: Double; var peak: Float }

    init(deviceID: AudioObjectID) { self.deviceID = deviceID }
    deinit { stop(); buf?.deallocate() }

    /// Input latency of the device in seconds: latency + safety offset + I/O buffer + stream latency.
    /// This is the delay between the sound reaching the microphone and the host timestamp of its samples.
    static func inputLatencySeconds(_ dev: AudioObjectID) -> (seconds: Double, rate: Double) {
        func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var sz = UInt32(4)
            return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : 0
        }
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0; var rsz = UInt32(8)
        if AudioObjectGetPropertyData(dev, &ra, 0, nil, &rsz, &rate) != noErr || rate <= 0 { rate = 48000 }
        var stream: UInt32 = 0
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                            mElement: kAudioObjectPropertyElementMain)
        var ssz: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &ssz) == noErr, ssz >= 4 {
            var ids = [AudioObjectID](repeating: 0, count: Int(ssz) / 4)
            if AudioObjectGetPropertyData(dev, &sa, 0, nil, &ssz, &ids) == noErr, let s0 = ids.first {
                var la = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
                var v: UInt32 = 0; var sz = UInt32(4)
                if AudioObjectGetPropertyData(s0, &la, 0, nil, &sz, &v) == noErr { stream = v }
            }
        }
        let frames = u32(dev, kAudioDevicePropertyLatency) + u32(dev, kAudioDevicePropertySafetyOffset)
            + u32(dev, kAudioDevicePropertyBufferFrameSize) + stream
        return (Double(frames) / rate, rate)
    }

    func start(maxSeconds: Double) throws {
        let info = Self.inputLatencySeconds(deviceID)
        rate = info.rate
        guard rate >= 8000, rate <= 192000 else { throw StartError.rate }
        capacity = Int(rate * maxSeconds)
        buf = .allocate(capacity: capacity); buf!.initialize(repeating: 0, count: capacity)

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw StartError.noDevice }
        var au: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &au)
        guard st == noErr, let au else { throw StartError.unit(st) }
        unit = au
        func set<T>(_ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ el: AudioUnitElement, _ v: T) -> OSStatus {
            var x = v; return AudioUnitSetProperty(au, prop, scope, el, &x, UInt32(MemoryLayout<T>.size))
        }
        var one: UInt32 = 1, zero: UInt32 = 0
        st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        if st == noErr { st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4) }
        if st == noErr { st = set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID) }
        // Client format: mono Float32 at the device rate (channel 0 of the device).
        let fmt = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 4,
                                              mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                              mBitsPerChannel: 32, mReserved: 0)
        if st == noErr { st = set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, fmt) }
        let cb = AURenderCallbackStruct(inputProc: { ref, flags, ts, bus, frames, _ in
            Unmanaged<MicRecorder>.fromOpaque(ref).takeUnretainedValue().input(flags, ts, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        if st == noErr { st = set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, cb) }
        if st == noErr { st = AudioUnitInitialize(au) }
        if st == noErr { st = AudioOutputUnitStart(au) }
        if st != noErr { stop(); throw StartError.unit(st) }
    }

    /// Realtime input callback: renders straight into the preallocated buffer. No allocation, no lock.
    private func input(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                       _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let au = unit, let buf else { return noErr }
        let w = written.load(ordering: .relaxed), n = Int(frames)
        guard w + n <= capacity else { return noErr }
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                                         mData: UnsafeMutableRawPointer(buf + w)))
        let st = AudioUnitRender(au, flags, ts, bus, frames, &abl)
        if st != noErr { failed.store(st, ordering: .relaxed); return st }
        let s = stampCount.load(ordering: .relaxed)
        if s < stampStart.count {
            stampStart.withUnsafeMutableBufferPointer { $0[s] = w }
            stampHost.withUnsafeMutableBufferPointer { $0[s] = ts.pointee.mHostTime }
            stampCount.store(s + 1, ordering: .releasing)
        }
        written.store(w + n, ordering: .releasing)
        return noErr
    }

    func stop() {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            unit = nil
        }
    }

    var framesRecorded: Int { written.load(ordering: .acquiring) }
    var renderFailure: OSStatus { failed.load(ordering: .relaxed) }

    /// Call after `stop()`. `startSeconds` is the host time of the first sample (host stamps, median over buffers).
    func recording() -> Recording? {
        let n = written.load(ordering: .acquiring), sc = stampCount.load(ordering: .acquiring)
        guard let buf, n > 0, sc >= 8 else { return nil }
        let out = Array(UnsafeBufferPointer(start: buf, count: n))
        var offs: [Double] = []
        for i in 0..<sc { offs.append(HostClock.seconds(stampHost[i]) - Double(stampStart[i]) / rate) }
        offs.sort()
        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        return Recording(samples: out, rate: rate, startSeconds: offs[offs.count / 2], peak: peak)
    }
}
