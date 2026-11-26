// Power state: battery vs. AC and Low Power Mode, so engines can save energy on battery.
import Foundation
import IOKit.ps

/// Thread-safe snapshot of the Mac's power state.
///
/// `saver` is true on battery power or in Low Power Mode. Engines read it on their own threads
/// (it is a lock-protected value, cheap to read every tick) and lower frame rates, poll rates and
/// analysis work while it is set. Observers can also listen for `PowerState.didChange`.
final class PowerState: @unchecked Sendable {
    static let shared = PowerState()
    static let didChange = Notification.Name("HapticGlowPowerStateDidChange")

    private let lock = NSLock()
    private var _onBattery = false
    private var _lowPower = false
    private var runLoopSource: CFRunLoopSource?

    /// Running on battery power.
    var onBattery: Bool { lock.withLock { _onBattery } }
    /// macOS Low Power Mode is on.
    var lowPower: Bool { lock.withLock { _lowPower } }
    /// Save energy: on battery or in Low Power Mode.
    var saver: Bool { lock.withLock { _onBattery || _lowPower } }

    private init() {
        refresh(notify: false)
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.refresh(notify: true)
        }
        // Power source changes (plugging in or out) arrive on the main run loop.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerState>.fromOpaque(ctx).takeUnretainedValue().refresh(notify: true)
        }, ctx)?.takeRetainedValue() {
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }

    private func refresh(notify: Bool) {
        let battery = Self.readOnBattery()
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        let changed: Bool = lock.withLock {
            let c = battery != _onBattery || low != _lowPower
            _onBattery = battery; _lowPower = low
            return c
        }
        if changed {
            Log.write("[power] onBattery=\(battery) lowPower=\(low)")
            if notify { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    private static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
