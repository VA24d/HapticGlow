// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Typing Practice: Words / Timed / Quotes / Code / Weak-keys drills with live metrics, a result card,
// a per-key heatmap and history. Keys are read through KeyCatcher (no beep); sound and glow still come
// from the system-wide KeyMonitor, so this page doubles as the real-keyboard "Try It".
import SwiftUI
import AppKit

struct PracticeView: View {
    /// Holds the session and creates it on first use, once per view identity.
    @MainActor private final class SessionBox {
        lazy var session: PracticeSession = {
            if let d = ProcessInfo.processInfo.environment["HAPTICGLOW_PRACTICE_DEMO"] { return PracticeSession.demo(d) }
            return PracticeSession()
        }()
    }
    @State private var box = SessionBox()
    private var s: PracticeSession { box.session }
    @State private var focused = true
    @State private var catcherActive = true
    @State private var metric: KeyHeatmap.Metric = .errors
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Typing Practice",
                           subtitle: "Type on your real keyboard. Every key uses your sound pack and lights the backlight.")
                modeBar
                if s.phase == .done, let m = s.metrics, let r = s.result {
                    ResultCard(m: m, r: r, mode: s.mode, next: { s.newTest(); refocus() }, again: { s.repeatTest(); refocus() })
                } else {
                    typingCard
                }
                heatmapCard
                historyCard
            }
            .pageLayout()
        }
        .background(Theme.window)
        .background(KeyCatcher(active: catcherActive, onKey: { s.handle($0) },
                               onFocusChange: { f in DispatchQueue.main.async { focused = f } }))
        .confirmationDialog("Reset all practice data?", isPresented: $confirmReset) {
            Button("Reset history and key stats", role: .destructive) { s.store.reset() }
        } message: { Text("Personal bests, history and per-key stats will be deleted.") }
    }

    private func refocus() {
        catcherActive = false
        DispatchQueue.main.async { catcherActive = true }
    }

    // MARK: mode bar

    private var modeBar: some View {
        Card(padding: Theme.Space.m) {
            HStack(spacing: Theme.Space.l) {
                Segmented(items: PracticeMode.allCases, selection: Binding(get: { s.mode }, set: { s.mode = $0; refocus() }),
                          title: \.title)
                Spacer(minLength: 0)
                switch s.mode {
                case .words, .weak:
                    Segmented(items: PracticeSession.wordOptions, selection: Binding(get: { s.wordCount }, set: { s.wordCount = $0; refocus() }),
                              title: { "\($0)" })
                case .timed:
                    Segmented(items: PracticeSession.timeOptions, selection: Binding(get: { s.timeLimit }, set: { s.timeLimit = $0; refocus() }),
                              title: { "\($0)s" })
                case .quotes: Text("One quote").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                case .code: Text("Three lines").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: typing area

    private var typingCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xl) {
                LiveStat(label: s.mode == .timed ? "Time" : "Words", value: s.counterText, accent: true)
                LiveStat(label: "WPM", value: s.phase == .running ? "\(Int(s.liveWPM.rounded()))" : "–")
                LiveStat(label: "Accuracy", value: s.phase == .running ? "\(Int(s.liveAccuracy.rounded()))%" : "–")
                BacklightStat()
                Spacer(minLength: 0)
                if let src = s.quoteSource { Text(src).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                if s.mode == .weak {
                    HStack(spacing: 4) {
                        Text("Focus").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        ForEach(Array(s.weakLetters.prefix(4)), id: \.self) { c in
                            Text(String(c)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.warn.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                                .foregroundStyle(Theme.warn)
                        }
                    }
                }
            }
            TypingTextView(words: s.engine.words, typed: s.engine.typed, current: s.engine.current,
                           idle: s.phase == .ready, focused: focused)
                .frame(height: TypingTextView.lineH * 3)
                .opacity(focused ? 1 : 0.35)
                .overlay {
                    if !focused {
                        Label("Click to focus and start typing", systemImage: "cursorarrow.click")
                            .font(Theme.Font.label).foregroundStyle(Theme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { refocus() }
            if s.needsDataNote {
                Text("Type a few Words or Timed tests first. Weak-key drills start from your own per-key stats; until then they use common words.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Theme.Space.l) {
                hint(["Tab", "Enter"], "new test")
                hint(["Esc"], "restart")
                hint(["Option", "Delete"], "delete word")
                Spacer(minLength: 0)
            }
        }
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { KbdChip($0) }
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: heatmap

    private var heatmapCard: some View {
        let byCode = PracticeKeyMap.byKeyCode(s.stats)
        let known = byCode.filter { $0.value.count >= AdaptiveGenerator.minSamples }
        let slow = known.compactMap { (c, v) in v.meanLatency.map { (c, $0) } }.sorted { $0.1 > $1.1 }.prefix(5)
        let missed = known.filter { $0.value.misses > 0 }.sorted { $0.value.missRate > $1.value.missRate }.prefix(5)
        func name(_ code: UInt16) -> String {
            let l = KeyLayout.caps.first { $0.keyCode == code }?.label ?? "?"
            return code == 49 ? "space" : l.lowercased()
        }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader("Your keyboard")
                Segmented(items: KeyHeatmap.Metric.allCases, selection: $metric, title: \.rawValue)
                    .fixedSize()
            }
            Card {
                KeyHeatmap(stats: s.stats, metric: metric).frame(maxWidth: 640).frame(maxWidth: .infinity)
                if known.isEmpty {
                    Text("Finish a test and your slowest and most-missed keys appear here.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        keyList("Slowest keys", slow.map { (name($0.0), "\(Int($0.1.rounded())) ms") })
                        keyList("Most missed", missed.map { (name($0.key), "\(Int(($0.value.missRate * 100).rounded()))%") })
                    }
                }
            }
        }
    }

    private func keyList(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            if rows.isEmpty { Text("None yet").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    Text(r.0).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 36, alignment: .leading)
                    Text(r.1).font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: history

    private var historyCard: some View {
        let data = s.store.data
        let bests = data.bests.sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader("History")
                if !data.history.isEmpty {
                    Button("Reset", role: .destructive) { confirmReset = true }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if data.history.isEmpty {
                Card { Text("No tests yet. Your results and personal bests will show up here.")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary) }
            } else {
                if !bests.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.s) {
                            ForEach(bests, id: \.key) { b in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Best \(b.key)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                    Text("\(Int(b.value.rounded())) wpm").font(Theme.Font.numeral.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                                }
                                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                            }
                        }
                    }
                }
                GroupCard {
                    ForEach(data.history.prefix(8)) { r in
                        HStack(spacing: Theme.Space.l) {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary).lineLimit(1).frame(width: 170, alignment: .leading)
                            Text(r.modeKey).font(Theme.Font.label).foregroundStyle(Theme.textPrimary).frame(width: 90, alignment: .leading)
                            Spacer(minLength: 0)
                            if r.isBest { Pill(text: "Best") }
                            Text("\(Int(r.wpm.rounded())) wpm").font(Theme.Font.numeral.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                            Text("\(Int(r.accuracy.rounded()))%").font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct Pill: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.ok)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.ok.opacity(0.14), in: Capsule())
    }
}

/// Live keyboard backlight: a bar that rises and falls with the hardware level, plus the percent.
/// Reads GlowEngine.currentLevel inside a Canvas each frame (a plain body would not re-render).
private struct BacklightStat: View {
    @State private var pulse = UIPulse.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BACKLIGHT").font(Theme.Font.section).tracking(0.5).foregroundStyle(Theme.textTertiary)
            HStack(alignment: .center, spacing: 8) {
                TimelineView(.animation(minimumInterval: pulse.frame(60), paused: !pulse.awake)) { _ in
                    Canvas { ctx, size in
                        let v = Double(max(0, min(1, GlowEngine.shared.currentLevel)))
                        let r = CGRect(origin: .zero, size: size)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Theme.track))
                        let h = size.height * v
                        if h > 0.5 {
                            let fill = CGRect(x: 0, y: size.height - h, width: size.width, height: h)
                            ctx.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(Theme.accent.opacity(0.35 + 0.65 * v)))
                        }
                    }
                }
                .frame(width: 8, height: 26)
                Polled(every: 0.1, read: { Int((max(0, min(1, GlowEngine.shared.currentLevel)) * 100).rounded()) }) { pct in
                    Text("\(pct)%")
                        .font(.system(size: 26, weight: .light).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 62, alignment: .leading)
                }
            }
        }
        .pulseConsumer()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keyboard backlight")
    }
}

private struct LiveStat: View {
    let label: String; let value: String; var accent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.Font.section).tracking(0.5).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 26, weight: .light).monospacedDigit())
                .foregroundStyle(accent ? Theme.accent : Theme.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}

/// Compact segmented control in the app's neutral style.
private struct Segmented<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    init(items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String) {
        self.items = items; self._selection = selection; self.title = title
    }
    init(items: [Item], selection: Binding<Item>, title: KeyPath<Item, String>) {
        self.init(items: items, selection: selection, title: { $0[keyPath: title] })
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button { withAnimation(Theme.snappy) { selection = item } } label: {
                    Text(title(item)).font(Theme.Font.label)
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous)
                            .strokeBorder(on ? Theme.hairlineStrong : Color.clear, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.control + 1, style: .continuous))
    }
}

/// Large monospaced text with per-character state and a gliding caret.
struct TypingTextView: View {
    static let fontSize: CGFloat = 24
    static let lineH: CGFloat = 40
    static let charW: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: f]).width
    }()
    let words: [String]; let typed: [String]; let current: Int; let idle: Bool; let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = UIPulse.shared

    var body: some View {
        GeometryReader { geo in
            let cols = max(8, Int(geo.size.width / Self.charW))
            let slots = TextWrap.slots(words: words, typed: typed, current: current, cols: cols)
            let ci = min(current, max(0, words.count - 1))
            let curLine = slots.isEmpty ? 0 : slots[ci].line
            let first = max(0, curLine - 1)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    let font = Font.system(size: Self.fontSize, design: .monospaced)
                    for (i, w) in words.enumerated() {
                        let slot = slots[i]
                        guard slot.line >= first, slot.line < first + 3 else { continue }
                        let t = Array(i < typed.count ? typed[i] : "")
                        let chars = Array(w)
                        let committed = i < current
                        let wrong = committed && t != chars
                        let y = CGFloat(slot.line - first) * Self.lineH
                        for j in 0..<slot.length {
                            let isExtra = j >= chars.count
                            let ch = isExtra ? t[j] : chars[j]
                            let color: Color
                            if j < t.count { color = isExtra ? Theme.err.opacity(0.75) : (t[j] == chars[j] ? Theme.textPrimary : Theme.err) }
                            else { color = committed ? Theme.err.opacity(0.55) : Theme.textSecondary.opacity(0.7) }
                            ctx.draw(Text(String(ch)).font(font).foregroundStyle(color),
                                     at: CGPoint(x: CGFloat(slot.col + j) * Self.charW, y: y + 3), anchor: .topLeading)
                        }
                        if wrong {
                            var p = Path()
                            let uy = y + Self.lineH - 6
                            p.move(to: CGPoint(x: CGFloat(slot.col) * Self.charW, y: uy))
                            p.addLine(to: CGPoint(x: CGFloat(slot.col + slot.length) * Self.charW, y: uy))
                            ctx.stroke(p, with: .color(Theme.err.opacity(0.7)), lineWidth: 1.5)
                        }
                    }
                }
                if current < words.count, !slots.isEmpty {
                    let slot = slots[ci]
                    let col = slot.col + min(typed[ci].count, slot.length)
                    // Hard blink like the system caret, only while idle, focused and visible; no timeline otherwise.
                    TimelineView(.animation(minimumInterval: 0.53, paused: !(idle && focused) || reduceMotion || !pulse.visible)) { tl in
                        let off = idle && focused && !reduceMotion && pulse.visible
                            && Int(tl.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 1
                        RoundedRectangle(cornerRadius: 1).fill(Theme.accent)
                            .frame(width: 2.5, height: Self.lineH - 12)
                            .opacity(off ? 0.15 : 1)
                    }
                        .offset(x: CGFloat(col) * Self.charW - 1, y: CGFloat(slot.line - first) * Self.lineH + 6)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.09), value: col)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.09), value: slot.line)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement()
        .accessibilityLabel(words.joined(separator: " "))
    }
}

private struct ResultCard: View {
    let m: TypingMetrics; let r: PracticeResult; let mode: PracticeMode
    let next: () -> Void; let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Result").font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
                if r.isBest { Pill(text: "Personal best") }
                Spacer(minLength: 0)
                Text(r.modeKey).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: Theme.Space.m) {
                StatTile(title: "WPM", value: "\(Int(m.wpm.rounded()))")
                StatTile(title: "Accuracy", value: "\(Int(m.accuracy.rounded()))", unit: "%")
                StatTile(title: "Raw", value: "\(Int(m.raw.rounded()))", unit: "wpm")
                StatTile(title: "Consistency", value: "\(Int(m.consistency.rounded()))", unit: "%")
                StatTile(title: "Time", value: m.seconds >= 10 ? "\(Int(m.seconds.rounded()))" : String(format: "%.1f", m.seconds), unit: "s")
            }
            Card {
                HStack(spacing: Theme.Space.l) {
                    Text("Speed").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                    legend(Theme.accent, "WPM"); legend(Theme.textTertiary, "Raw"); legend(Theme.err, "Error")
                    Spacer(minLength: 0)
                    Text("\(m.correctChars) correct  \(m.incorrectChars) wrong  \(m.extraChars) extra  \(m.missedChars) missed")
                        .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                WPMChart(wpm: m.wpmSamples, raw: m.rawSamples, errors: m.errorSamples).frame(height: 150)
                if !m.errorsByKey.isEmpty {
                    HStack(spacing: 6) {
                        Text("Errors by key").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        ForEach(m.errorsByKey.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10), id: \.key) { k, v in
                            HStack(spacing: 3) {
                                Text(k == " " ? "space" : k).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Text("\(v)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.err.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                            .foregroundStyle(Theme.err)
                        }
                    }
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button(action: next) { Label("Next test", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                Button(action: again) { Label("Repeat", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).controlSize(.regular)
                Spacer(minLength: 0)
                HStack(spacing: 4) { KbdChip("Tab"); KbdChip("Enter"); Text("next").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
