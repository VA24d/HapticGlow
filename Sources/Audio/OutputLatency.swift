// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow — default output device latency (capture -> ear delay).
//
// The process tap sees samples before the output device plays them. Total delay to the ear is
//   (device latency + safety offset + buffer frames + stream latency) / sample rate.
// Bluetooth devices report a large static value (A2DP ~150-250 ms). We publish the raw figure to
// SyncClock.outputLatency; consumers (glow, haptics) add their own pipeline compensation and the
// user can fine-tune with SyncConfig.offsetMs.
import Foundation
import CoreAudio

struct OutputLatencyInfo: Sendable, Equatable {
    var deviceID: AudioObjectID = 0
    var name: String = ""
    var seconds: Double = 0
    var sampleRate: Double = 0
    var deviceFrames: UInt32 = 0
    var safetyFrames: UInt32 = 0
    var bufferFrames: UInt32 = 0
    var streamFrames: UInt32 = 0
    var transport: UInt32 = 0
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

final class OutputLatency: @unchecked Sendable {
    static let shared = OutputLatency()

    private let queue = DispatchQueue(label: "hapticglow.outputlatency", qos: .utility)
    private let lock = UnfairLock()
    private var started = false
    private var watched: AudioObjectID = 0
    private var sysBlock: AudioObjectPropertyListenerBlock?
    private var devBlock: AudioObjectPropertyListenerBlock?
    private var _info = OutputLatencyInfo()

    var info: OutputLatencyInfo { lock.withLock { _info } }

    private static let sysSelectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDefaultOutputDevice]
    private static let devSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize,
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreams,
    ]

    func start() {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        queue.async { [self] in
            let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(rewatch: true) }
            sysBlock = blk
            for s in Self.sysSelectors {
                var a = Self.addr(s)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, blk)
            }
            refresh(rewatch: true)
        }
    }

    func stop() {
        lock.lock(); let was = started; started = false; lock.unlock()
        guard was else { return }
        queue.async { [self] in
            if let b = sysBlock {
                for s in Self.sysSelectors {
                    var a = Self.addr(s)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, b)
                }
            }
            unwatch()
            sysBlock = nil
        }
    }

    // MARK: query

    private static func addr(_ s: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func u32(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var a = addr(s, scope: scope); var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }

    /// Reads the current default output device. Pure property reads: silent, safe to call anywhere.
    static func queryDefault() -> OutputLatencyInfo? {
        var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr,
              dev != 0 else { return nil }
        var i = OutputLatencyInfo(); i.deviceID = dev
        let out = kAudioObjectPropertyScopeOutput
        i.deviceFrames = u32(dev, kAudioDevicePropertyLatency, scope: out) ?? 0
        i.safetyFrames = u32(dev, kAudioDevicePropertySafetyOffset, scope: out) ?? 0
        i.bufferFrames = u32(dev, kAudioDevicePropertyBufferFrameSize, scope: out) ?? 0
        i.transport = u32(dev, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        var sa = addr(kAudioDevicePropertyNominalSampleRate); var rate: Float64 = 0
        sz = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(dev, &sa, 0, nil, &sz, &rate) != noErr || rate <= 0 { rate = 48000 }
        i.sampleRate = rate
        // first output stream latency
        var stA = addr(kAudioDevicePropertyStreams, scope: out)
        var ssz: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &stA, 0, nil, &ssz) == noErr, ssz >= 4 {
            var ids = [AudioObjectID](repeating: 0, count: Int(ssz) / 4)
            if AudioObjectGetPropertyData(dev, &stA, 0, nil, &ssz, &ids) == noErr, let s0 = ids.first {
                i.streamFrames = u32(s0, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal) ?? 0
            }
        }
        var nA = addr(kAudioObjectPropertyName); var cf: Unmanaged<CFString>?
        sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(dev, &nA, 0, nil, &sz, &cf) == noErr, let c = cf { i.name = c.takeRetainedValue() as String }
        let frames = Double(i.deviceFrames) + Double(i.safetyFrames) + Double(i.bufferFrames) + Double(i.streamFrames)
        i.seconds = frames / rate
        return i
    }

    // MARK: listening

    /// The nominal rate is a global-scope property (it is read that way); the others live on the output scope.
    private static func scope(of s: AudioObjectPropertySelector) -> AudioObjectPropertyScope {
        s == kAudioDevicePropertyNominalSampleRate ? kAudioObjectPropertyScopeGlobal : kAudioObjectPropertyScopeOutput
    }

    private func unwatch() {
        if watched != 0, let b = devBlock {
            for s in Self.devSelectors {
                var a = Self.addr(s, scope: Self.scope(of: s))
                AudioObjectRemovePropertyListenerBlock(watched, &a, queue, b)
            }
        }
        watched = 0; devBlock = nil
    }

    private func refresh(rewatch: Bool) {
        guard let i = Self.queryDefault() else { return }
        if rewatch && i.deviceID != watched {
            unwatch()
            let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(rewatch: false) }
            devBlock = blk; watched = i.deviceID
            for s in Self.devSelectors {
                var a = Self.addr(s, scope: Self.scope(of: s))
                AudioObjectAddPropertyListenerBlock(i.deviceID, &a, queue, blk)
            }
        }
        let changed: Bool = lock.withLock { let c = _info != i; _info = i; return c }
        SyncClock.shared.outputLatency = i.seconds
        guard changed else { return }
        Log.write(String(format: "[sync] output '%@' latency %.1f ms (dev %u + safety %u + buf %u + stream %u frames @ %.0f Hz)%@",
                         i.name, i.seconds * 1000, i.deviceFrames, i.safetyFrames, i.bufferFrames, i.streamFrames,
                         i.sampleRate, i.isBluetooth ? " bluetooth" : ""))
        let name = i.name, ms = i.seconds * 1000
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppModel.shared.outputDeviceName = name
                AppModel.shared.outputLatencyMs = ms
            }
        }
    }
}
