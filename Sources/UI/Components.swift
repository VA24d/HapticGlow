// Shared UI building blocks. Names are FROZEN (both UI agents use them); styling may be refined.
import SwiftUI
import AppKit

/// Page title + subtitle at the top of each detail screen.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            if let subtitle { Text(subtitle).font(Theme.Font.body).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small-caps section label.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(Theme.Font.section)
            .tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Surface card with hairline border.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Big numeric stat tile.
struct StatTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.Font.bigStat).foregroundStyle(Theme.textPrimary).contentTransition(.numericText())
                if let unit { Text(unit).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Labelled slider with live value readout. `format` renders the value (e.g. { "\(Int($0 * 100))%" }).
struct SliderRow: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var step: Float? = nil
    var format: (Float) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var help: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(format(value)).font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
            }
            if let step {
                // Round in the binding: Slider(step:) draws one tick per step (hundreds of dots).
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                    .controlSize(.small)
            } else {
                Slider(value: $value, in: range).controlSize(.small)
            }
            if let help { Text(help).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
        }
        .help(help ?? title)
    }
}

/// Labelled switch row.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                if let subtitle { Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden()
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// Coloured dot for an engine status.
struct StatusDot: View {
    let status: EngineStatus
    var size: CGFloat = 7
    var color: Color {
        switch status {
        case .running: return Theme.ok
        case .starting: return Theme.warn
        case .needsPermission, .unavailable: return Theme.warn
        case .failed: return Theme.err
        case .stopped: return Theme.textTertiary
        }
    }
    var body: some View { Circle().fill(color).frame(width: size, height: size).animation(Theme.snappy, value: status) }
}

/// Keyboard shortcut hint chip, e.g. KbdChip("⌘↩").
struct KbdChip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
            .opacity(0.8)
    }
}

/// Status chip with dot + text (used in permission rows / toolbars).
struct StatusChip: View {
    let text: String
    let status: EngineStatus
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, size: 6)
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

extension AudioInputState {
    /// Map capture state onto the generic status palette.
    var engineStatus: EngineStatus {
        switch self {
        case .active: return .running
        case .starting, .idleNoAudio: return .starting
        case .inactive: return .stopped
        case .needsPermission: return .needsPermission("System Audio Recording")
        case .unsupported: return .unavailable("Unsupported")
        case .stalled: return .failed("Stalled")
        case .failed(let s): return .failed(s)
        }
    }
}

extension View {
    /// Shared page container: one max width, 24 pt gutters, left-aligned, centred in wide windows.
    func pageLayout() -> some View {
        frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
    }
}

/// Card whose direct children are rows separated by hairlines (grouped-list look).
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                    row.padding(.vertical, Theme.Space.m)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

// MARK: - Change-driven live updates

/// Shared activity gate for live meters. While any meter is on screen it samples the engine at 20 Hz
/// (10 Hz on battery) and flips `awake` only on transitions, so meters can pause their per-frame
/// TimelineViews when the backlight level is steady and the audio is silent (with a settle window so
/// decays finish). It also tracks window visibility (hidden, minimised or fully occluded windows
/// animate nothing) and the power-saver state, which lowers frame rates.
@MainActor
@Observable
final class UIPulse {
    static let shared = UIPulse()
    /// Engine is active (audio, level or cutoff moving) and a window is visible.
    private(set) var awake = true
    /// At least one app window is actually visible to the user.
    private(set) var visible = true
    /// On battery or Low Power Mode.
    private(set) var saver = PowerState.shared.saver
    @ObservationIgnored private var engineActive = true
    @ObservationIgnored private var consumers = 0
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var timerSaver = false
    @ObservationIgnored private var lastLevel: Float = -1
    @ObservationIgnored private var lastCutoff: Float = -1
    @ObservationIgnored private var lastActive: Double = 0
    private let settle: Double = 1.6

    /// True when any app window can be seen: not hidden, not minimised, not fully covered.
    nonisolated static func anyWindowVisible(excluding: NSWindow? = nil) -> Bool {
        MainActor.assumeIsolated {
            guard !NSApp.isHidden else { return false }
            return NSApp.windows.contains { w in
                w !== excluding && isContentWindow(w)
                    && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
            }
        }
    }

    /// Real content windows and the menu-bar panel (while shown). The status-item window and
    /// tooltip-like helpers do not count.
    private static func isContentWindow(_ w: NSWindow) -> Bool {
        let cls = NSStringFromClass(type(of: w))
        if cls.contains("StatusBar") || cls.contains("StatusItem") { return false }
        guard w.canBecomeMain || w is NSPanel else { return false }
        return w.frame.height > 40
    }

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: PowerState.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSaver() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisible() }
            }
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let w = note.object as? NSWindow
            MainActor.assumeIsolated { self?.refreshVisible(excluding: w) }
        }
    }

    /// Frame interval for a meter that wants `fps` on AC. Capped at 30 fps on battery (15 for previews).
    func frame(_ fps: Double, preview: Bool = false) -> TimeInterval {
        saver ? 1.0 / min(fps, preview ? 15 : 30) : 1.0 / fps
    }

    /// Interval for slow readouts: doubled on battery.
    func slow(_ base: TimeInterval) -> TimeInterval { saver ? base * 2 : base }

    private func refreshSaver() {
        let s = PowerState.shared.saver
        if s != saver { saver = s }
        if timer != nil && timerSaver != s { stopTimer(); startTimer() }
    }

    func refreshVisible(excluding: NSWindow? = nil) {
        let v = Self.anyWindowVisible(excluding: excluding)
        if v != visible {
            visible = v
            if v {
                lastActive = hostNow()
                engineActive = true
            }
        }
        let a = engineActive && v
        if a != awake { awake = a }
        if !v {
            stopTimer()
        } else if consumers > 0 && timer == nil {
            startTimer()
        }
    }

    private func startTimer() {
        let s = PowerState.shared.saver
        timerSaver = s
        let ms = s ? 100 : 50
        let t = DispatchSource.makeTimerSource(flags: [], queue: .main)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(ms / 4))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.poll() } }
        timer = t
        t.resume()
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    func retain() {
        consumers += 1
        if consumers == 1 {
            lastActive = hostNow()
            engineActive = true
            refreshVisible()
        } else if visible && timer == nil {
            startTimer()
        }
    }

    func release() {
        consumers = max(0, consumers - 1)
        if consumers == 0 { stopTimer() }
    }

    private func poll() {
        let now = hostNow()
        refreshVisible()
        guard visible else { return }   // nothing is drawn; skip engine sampling too
        let level = GlowEngine.shared.currentLevel
        let f = FeatureBus.shared.latest()
        let cutoff = FeatureBus.shared.cutoffHz
        if !f.silent || abs(level - lastLevel) > 0.0005 || cutoff != lastCutoff { lastActive = now }
        lastLevel = level
        lastCutoff = cutoff
        let a = now - lastActive < settle
        if a != engineActive { engineActive = a }
        let w = a && visible
        if w != awake { awake = w }
    }
}

private struct ShownConsumer: ViewModifier {
    @Binding var shown: Bool
    @State private var held = false
    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityProbe { v in
                if shown != v { shown = v }
                if v != held {
                    held = v
                    if v { UIPulse.shared.retain() } else { UIPulse.shared.release() }
                }
            })
            .onDisappear {
                if held { held = false; UIPulse.shared.release() }
                shown = false
            }
    }
}

extension View {
    /// Like `pulseConsumer`, but counts only while the hosting window is really shown
    /// (panels that stay alive after closing do not keep sampling).
    func shownConsumer(_ shown: Binding<Bool>) -> some View {
        modifier(ShownConsumer(shown: shown))
    }

    /// Keeps `UIPulse` sampling while this view is on screen.
    func pulseConsumer() -> some View {
        onAppear { UIPulse.shared.retain() }.onDisappear { UIPulse.shared.release() }
    }
}

@MainActor
private final class PolledDriver {
    private var timer: DispatchSourceTimer?
    private var running = false
    private var scheduledSaver = false
    var interval: TimeInterval = 0.2
    var onTick: (() -> Void)?

    func start(interval: TimeInterval, saver: Bool, visible: Bool, onTick: @escaping () -> Void) {
        self.interval = interval
        self.onTick = onTick
        running = true
        sync(saver: saver, visible: visible)
    }

    func sync(saver: Bool, visible: Bool) {
        guard running, visible else {
            timer?.cancel(); timer = nil
            return
        }
        if timer != nil && scheduledSaver == saver { return }
        timer?.cancel(); timer = nil
        scheduledSaver = saver
        let sec = saver ? interval * 2 : interval
        let ms = max(16, Int((sec * 1000).rounded()))
        let leewayMs = max(4, ms * 3 / 10)
        let t = DispatchSource.makeTimerSource(flags: [], queue: .main)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(leewayMs))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        timer = t
        t.resume()
    }

    func stop() {
        running = false
        timer?.cancel(); timer = nil
        onTick = nil
    }

    deinit { timer?.cancel() }
}

/// Re-reads a value on a timer but only re-evaluates `content` when the value changed, so unchanged
/// text never invalidates the view graph or triggers layout and commit. Lengthens its interval on
/// battery and pauses completely while all windows are hidden or occluded.
struct Polled<V: Equatable, Content: View>: View {
    let interval: TimeInterval
    let read: () -> V
    let content: (V) -> Content
    @State private var value: V
    @State private var driver = PolledDriver()
    @State private var pulse = UIPulse.shared

    init(every interval: TimeInterval, read: @escaping () -> V, @ViewBuilder content: @escaping (V) -> Content) {
        self.interval = interval; self.read = read; self.content = content
        _value = State(initialValue: read())
    }

    var body: some View {
        content(value)
            .onAppear {
                pulse.refreshVisible()
                refresh()
                driver.start(interval: interval, saver: pulse.saver, visible: pulse.visible) {
                    refresh()
                }
            }
            .onDisappear { driver.stop() }
            .onChange(of: pulse.visible) { _, v in
                if v { refresh() }
                driver.sync(saver: pulse.saver, visible: v)
            }
            .onChange(of: pulse.saver) { _, s in
                driver.sync(saver: s, visible: pulse.visible)
            }
    }

    private func refresh() {
        let n = read()
        if n != value { value = n }
    }
}
