// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Backlight hardware probe (visual only, no sound). Usage: backlight_probe <phase>
// phases: info | hid | curve | step | track | cost
import Foundation
import IOKit
import IOKit.hid

@objc protocol KBC {
    @objc(copyKeyboardBacklightIDs) func ids() -> [NSNumber]
    @objc(isKeyboardBuiltIn:) func builtIn(_ k: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func get(_ k: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func set(_ b: Float, forKeyboard k: UInt64) -> Bool
    @objc(setBrightness:fadeSpeed:commit:forKeyboard:) func setF(_ b: Float, fadeSpeed: Int32, commit: Bool, forKeyboard k: UInt64) -> Bool
    @objc(enableAutoBrightness:forKeyboard:) func auto(_ e: Bool, forKeyboard k: UInt64) -> Bool
    @objc(isAutoBrightnessEnabledForKeyboard:) func isAuto(_ k: UInt64) -> Bool
    @objc(idleDimTimeForKeyboard:) func idle(_ k: UInt64) -> Double
    @objc(setIdleDimTime:forKeyboard:) func setIdle(_ t: Double, forKeyboard k: UInt64) -> Bool
    @objc(suspendIdleDimming:forKeyboard:) func susp(_ s: Bool, forKeyboard k: UInt64) -> Bool
    @objc(isIdleDimmingSuspendedOnKeyboard:) func isSusp(_ k: UInt64) -> Bool
}
dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
let o = (NSClassFromString("KeyboardBrightnessClient") as! NSObject.Type).init()
let c = unsafeBitCast(o, to: KBC.self)
let kb = c.ids().map { $0.uint64Value }.first { c.builtIn($0) }!

func now() -> Double { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(mach_absolute_time()) * Double(t.numer) / Double(t.denom) / 1e9 }

// IORegistry PWM
var pwmEntry: io_registry_entry_t = 0
do {
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPWMDevice"), &it)
    while case let e = IOIteratorNext(it), e != 0 {
        var nm = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(e, &nm)
        if String(cString: nm) == "kbd-backlight" { pwmEntry = e; break }
        IOObjectRelease(e)
    }
}
func prop(_ k: String) -> Int {
    (IORegistryEntryCreateCFProperty(pwmEntry, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
}
func duty() -> Int { prop("high-period") }
func period() -> Int { prop("high-period") + prop("low-period") }

struct Saved { var b: Float; var auto: Bool; var idle: Double; var susp: Bool }
let saved = Saved(b: c.get(kb), auto: c.isAuto(kb), idle: c.idle(kb), susp: c.isSusp(kb))
func restore() {
    _ = c.susp(false, forKeyboard: kb); _ = c.setIdle(saved.idle, forKeyboard: kb)
    _ = c.auto(saved.auto, forKeyboard: kb); _ = c.setF(saved.b, fadeSpeed: 0, commit: true, forKeyboard: kb)
    if saved.susp { _ = c.susp(true, forKeyboard: kb) }
}
func fz(_ v: Float) { _ = c.setF(v, fadeSpeed: 0, commit: false, forKeyboard: kb) }
func take() { _ = c.auto(false, forKeyboard: kb); _ = c.susp(true, forKeyboard: kb) }
func settle(_ s: Double = 0.4) { Thread.sleep(forTimeInterval: s) }
let phase = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "info"
func out(_ s: String) { print(s); fflush(stdout) }
out("saved b=\(saved.b) auto=\(saved.auto) idle=\(saved.idle) susp=\(saved.susp) kb=\(kb) pwmEntry=\(pwmEntry != 0)")

switch phase {
case "info":
    // read rate and liveness
    let n = 2000; let t0 = now(); var last = 0
    for _ in 0..<n { last = duty() }
    out("ioreg read: \(String(format: "%.1f", (now()-t0)/Double(n)*1e6)) us/read, duty=\(last) period=\(period())")
    // all pwm props
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(pwmEntry, &props, kCFAllocatorDefault, 0)
    if let d = props?.takeRetainedValue() as? [String: Any] { for (k, v) in d.sorted(by: { $0.key < $1.key }) { let s = "\(v)"; out("  \(k) = \(s.prefix(160))") } }
case "hid":
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 0x0F] as CFDictionary)
    let r0 = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    out("manager open: \(String(format: "0x%x", r0))")
    let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    out("devices: \(devs.count)")
    for d in devs {
        let name = String(describing: IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString))
        out("dev product=\(name) maxFeature=\(String(describing: IOHIDDeviceGetProperty(d, kIOHIDMaxFeatureReportSizeKey as CFString)))")
        let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        out("  IOHIDDeviceOpen: \(String(format: "0x%x", r))")
        if let els = IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement] {
            for e in els { out("  el id=\(IOHIDElementGetReportID(e)) type=\(IOHIDElementGetType(e).rawValue) page=\(String(format:"0x%x",IOHIDElementGetUsagePage(e))) usage=\(String(format:"0x%x",IOHIDElementGetUsage(e))) bits=\(IOHIDElementGetReportSize(e)) lmin=\(IOHIDElementGetLogicalMin(e)) lmax=\(IOHIDElementGetLogicalMax(e)) unit=\(IOHIDElementGetUnit(e)) exp=\(IOHIDElementGetUnitExponent(e))") }
        }
        for id in 1...4 {
            var buf = [UInt8](repeating: 0, count: 64); var len = 64
            let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len)
            out("  GetReport feature id=\(id): \(String(format: "0x%x", r)) len=\(len) bytes=\(buf.prefix(min(len, 24)).map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
    }
case "curve":
    take(); fz(0); settle(0.3)
    var levels = Set<Int>(); var rows: [String] = []
    let N = 128
    for i in 0...N {
        let v = Float(i) / Float(N)
        fz(v); settle(0.05)
        let d = duty(); levels.insert(d)
        rows.append("\(String(format: "%.4f", v)),\(d),\(c.get(kb))")
    }
    try? rows.joined(separator: "\n").write(toFile: "build/tests/backlight-hw/curve.csv", atomically: true, encoding: .utf8)
    out("curve points=\(N+1) distinct duty=\(levels.count) min=\(levels.min()!) max=\(levels.max()!) period=\(period())")
    // fine sweep at low end: 0..0.02 in 200 steps
    var low = Set<Int>()
    for i in 0...200 { fz(Float(i) / 10000); settle(0.03); low.insert(duty()) }
    out("fine 0..0.02 (201 steps): distinct duty=\(low.count) vals=\(low.sorted().prefix(30))")
    // fine sweep around mid
    var mid = Set<Int>()
    for i in 0...200 { fz(0.5 + Float(i) / 20000); settle(0.03); mid.insert(duty()) }
    out("fine 0.5..0.51 (201 steps): distinct duty=\(mid.count) vals=\(mid.sorted().prefix(30))")
case "step":
    take()
    func step(_ label: String, _ f: () -> Void) {
        _ = c.set(0.1, forKeyboard: kb); settle(0.8)
        let base = duty()
        let t0 = now(); f()
        var tFirst = -1.0, tEnd = -1.0, lastV = base, tmax = 1.2
        var final = base
        while now() - t0 < tmax {
            let d = duty(); let t = now() - t0
            if d != base && tFirst < 0 { tFirst = t }
            if d != lastV { lastV = d; tEnd = t }
            final = d
        }
        out("\(label): base=\(base) final=\(final) firstChange=\(tFirst < 0 ? "none" : String(format: "%.1fms", tFirst*1000)) lastChange=\(tEnd < 0 ? "none" : String(format: "%.1fms", tEnd*1000))")
    }
    step("set:forKeyboard 0.1->0.9") { _ = c.set(0.9, forKeyboard: kb) }
    for fs in [0, 1, 10, 100, 1000] as [Int32] {
        for cm in [true, false] {
            step("fade=\(fs) commit=\(cm)") { _ = c.setF(0.9, fadeSpeed: fs, commit: cm, forKeyboard: kb) }
        }
    }
case "track":
    take()
    for rate in [120.0, 240.0] {
        for api in ["plain", "fade0nocommit"] {
            _ = c.set(0.5, forKeyboard: kb); settle(0.5)
            // sample duty in a separate thread at max rate
            nonisolated(unsafe) var samples: [(Double, Int)] = []
            nonisolated(unsafe) var run = true
            let th = Thread { while run { samples.append((now(), duty())) } }
            th.start()
            let t0 = now(); var sent: [(Double, Float)] = []; var i = 0
            while now() - t0 < 3.0 {
                let t = now() - t0
                if t >= Double(i) / rate {
                    let v = Float(0.5 + 0.45 * sin(2 * .pi * 2 * t))
                    if api == "plain" { _ = c.set(v, forKeyboard: kb) } else { _ = c.setF(v, fadeSpeed: 0, commit: false, forKeyboard: kb) }
                    sent.append((now(), v)); i += 1
                }
            }
            run = false; Thread.sleep(forTimeInterval: 0.05)
            let s = samples
            // map duty -> expected: use duty at v from curve approx linear fit by sample min/max
            let dmin = Double(s.map { $0.1 }.min()!), dmax = Double(s.map { $0.1 }.max()!)
            // best lag: correlate normalized duty with sine over lag candidates
            var best = (0.0, -2.0)
            for lagMs in stride(from: 0.0, through: 120.0, by: 1.0) {
                var sxy = 0.0, sxx = 0.0, syy = 0.0
                for (t, d) in s where t - t0 > 0.5 {
                    let tt = t - t0 - lagMs / 1000
                    let x = sin(2 * .pi * 2 * tt); let y = (Double(d) - (dmin + dmax) / 2) / ((dmax - dmin) / 2 + 1e-9)
                    sxy += x * y; sxx += x * x; syy += y * y
                }
                let r = sxy / (sqrt(sxx * syy) + 1e-9)
                if r > best.1 { best = (lagMs, r) }
            }
            // distinct duty updates observed per second
            var changes = 0; var prev = s.first!.1
            for (_, d) in s { if d != prev { changes += 1; prev = d } }
            out("track \(Int(rate))Hz \(api): sent=\(sent.count) (\(String(format: "%.0f", Double(sent.count)/3))/s) duty range \(Int(dmin))...\(Int(dmax)) sampled=\(s.count) dutyChanges/s=\(String(format: "%.0f", Double(changes)/3)) bestLag=\(best.0)ms corr=\(String(format: "%.3f", best.1))")
        }
    }
case "hidset":
    take()
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 0x0F] as CFDictionary)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    let d = ((IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []).first!
    IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    func hset(_ nits: UInt32, _ ms: UInt32) -> IOReturn {
        var b = [UInt8](repeating: 0, count: 9); b[0] = 1
        withUnsafeBytes(of: nits.littleEndian) { for i in 0..<4 { b[1+i] = $0[i] } }
        withUnsafeBytes(of: ms.littleEndian) { for i in 0..<4 { b[5+i] = $0[i] } }
        return IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 1, b, 9)
    }
    fz(0.1); settle(0.6); let base = duty()
    for (nits, ms) in [(UInt32(8000), UInt32(0)), (UInt32(2000), UInt32(0)), (UInt32(8000), UInt32(100))] {
        let t0 = now(); let r = hset(nits, ms); let tw = now() - t0
        var tFirst = -1.0, lastC = 0.0, lastV = duty(), prev0 = lastV
        while now() - t0 < 0.5 { let v = duty(); if v != prev0 && tFirst < 0 { tFirst = now() - t0 }; if v != lastV { lastV = v; lastC = now() - t0 } }
        out("HID set nits=\(nits) ms=\(ms): ret=\(String(format: "0x%x", r)) write=\(String(format: "%.0f", tw*1e6))us duty \(prev0)->\(lastV) first=\(String(format: "%.1f", tFirst*1000))ms last=\(String(format: "%.1f", lastC*1000))ms cb.get=\(c.get(kb))")
        settle(0.3)
    }
    // cost + duty values for 3 nits points
    for nits in [UInt32(100), UInt32(1000), UInt32(4000), UInt32(14660)] { _ = hset(nits, 0); settle(0.1); out("  nits=\(nits) -> duty \(duty())") }
    let n = 1000; let t0 = now(); for i in 0..<n { _ = hset(UInt32(2000 + i % 1000), 0) }; out("HID write cost \(String(format: "%.1f", (now()-t0)/Double(n)*1e6)) us")
case "low":
    take(); fz(0.5); settle(0.2)
    for v in [0.0, 0.0005, 0.001, 0.002, 0.004, 0.008, 0.016, 0.03, 0.06] as [Float] { fz(v); settle(0.15); out("v=\(v) duty=\(duty())") }
    fz(0.5); settle(0.1); fz(0); settle(0.2); out("after 0.5->0: duty=\(duty())")
case "zero":
    take()
    for (lab, f) in [("fade1 commit=true", { _ = c.setF(0, fadeSpeed: 1, commit: true, forKeyboard: kb) }), ("fade20 commit=false", { _ = c.setF(0, fadeSpeed: 20, commit: false, forKeyboard: kb) }), ("fade20 commit=true", { _ = c.setF(0, fadeSpeed: 20, commit: true, forKeyboard: kb) }), ("fade0 commit=true -0", { _ = c.setF(-0.0, fadeSpeed: 0, commit: true, forKeyboard: kb) }), ("fade0 v=1e-9", { _ = c.setF(1e-9, fadeSpeed: 0, commit: true, forKeyboard: kb) })] as [(String, () -> Void)] {
        fz(0.5); settle(0.2); let t0 = now(); f(); var tf = -1.0; let d0 = duty()
        while now() - t0 < 0.6 { if duty() != d0 && tf < 0 { tf = now() - t0 } }
        out("zero via \(lab): duty \(d0)->\(duty()) first=\(String(format: "%.1f", tf*1000))ms")
    }
case "cost":
    take()
    for api in ["plain", "fade0nocommit"] {
        let n = 1000; var tot = 0.0; var worst = 0.0
        var cpu0 = rusage(); getrusage(RUSAGE_SELF, &cpu0)
        let w0 = now()
        for i in 0..<n {
            let v = Float(0.3 + 0.4 * Double(i % 100) / 100)
            let t = now()
            if api == "plain" { _ = c.set(v, forKeyboard: kb) } else { _ = c.setF(v, fadeSpeed: 0, commit: false, forKeyboard: kb) }
            let dt = now() - t; tot += dt; worst = max(worst, dt)
        }
        var cpu1 = rusage(); getrusage(RUSAGE_SELF, &cpu1)
        func tv(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let cpu = (tv(cpu1.ru_utime) + tv(cpu1.ru_stime)) - (tv(cpu0.ru_utime) + tv(cpu0.ru_stime))
        out("cost \(api): n=\(n) avg=\(String(format: "%.1f", tot/Double(n)*1e6))us worst=\(String(format: "%.0f", worst*1e6))us cpu/write=\(String(format: "%.1f", cpu/Double(n)*1e6))us wall=\(String(format: "%.2f", now()-w0))s")
    }
default: break
}
restore()
let rb = (c.get(kb), c.isAuto(kb), c.idle(kb), c.isSusp(kb))
out("restored -> b=\(rb.0) auto=\(rb.1) idle=\(rb.2) susp=\(rb.3)")
