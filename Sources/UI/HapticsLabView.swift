// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Haptics Lab section for the Trackpad Haptics page: manual primitives, governor readout, guided feel test.
import SwiftUI

struct HapticsLabSection: View {
    @State private var open: Bool = ProcessInfo.processInfo.environment["HAPTICGLOW_SNAPSHOT_DIR"] != nil
    @State private var page: Page = .manual
    private enum Page: String, CaseIterable, Identifiable { case manual = "Manual", feel = "Feel test"; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { withAnimation(Theme.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Theme.textTertiary).frame(width: 10)
                        .accessibilityHidden(true)
                    Text("HAPTICS LAB").font(Theme.Font.section).tracking(0.6).foregroundStyle(Theme.textSecondary)
                    Text("Low-level controls and a guided feel test").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Haptics Lab")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Picker("Page", selection: $page) { ForEach(Page.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    safetyNote
                    switch page {
                    case .manual: HapticsLabManual()
                    case .feel: HapticsFeelTest()
                    }
                    GovernorReadout()
                }
            }
        }
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield").foregroundStyle(Theme.ok).font(.system(size: 13))
            Text("Every call passes through one limiter built from Apple's own actuator table: amplitude times level never exceeds 48, pulses are 2 to 12 ms, tones stop at 80 ms, and rate, duty and a stall guard cap the rest. Nothing on this page can overdrive the motor.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

// MARK: - Manual

private struct HapticsLabManual: View {
    @Bindable var lab = HapticsLabModel.shared
    @Bindable var app = AppModel.shared

    var body: some View {
        Card {
            HStack(spacing: Theme.Space.m) {
                Picker("Primitive", selection: $lab.primitive) { ForEach(LabPrimitive.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Button { lab.play() } label: {
                    HStack(spacing: 6) { Image(systemName: "play.fill").font(.system(size: 10)); Text("Play") }.frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play (Space)")
            }
            controls
            HStack(spacing: 8) {
                if let rc = lab.lastRC {
                    let r = lab.rcText(rc)
                    Image(systemName: r.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(r.ok ? Theme.ok : Theme.warn).font(.system(size: 11))
                    Text(r.text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Press Play or Space. Nothing plays until you do.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                KbdChip("Space")
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            presets
        }
    }

    @ViewBuilder private var controls: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.l) {
            switch lab.primitive {
            case .pulse, .train:
                GridRow {
                    SliderRow(title: "Amplitude", value: $lab.amplitude, range: 0...48, step: 1,
                              format: { "\(Int($0))" }, help: "Gaussian height. Effective \(Int(lab.effectiveAmplitude)) of 48 after level.")
                    SliderRow(title: "Width", value: $lab.width, range: 2...12, step: 0.5,
                              format: { String(format: "%.1f ms", $0) }, help: "Wider is rounder and lower. 2 to 12 ms.")
                }
                GridRow {
                    levelRow
                    if lab.primitive == .train {
                        SliderRow(title: "Train rate", value: $lab.rate, range: 10...80, step: 1,
                                  format: { "\(Int($0)) Hz" }, help: "Pulses per second.")
                    } else { brakeRow }
                }
                if lab.primitive == .train {
                    GridRow {
                        SliderRow(title: "Count", value: $lab.count, range: 1...20, step: 1,
                                  format: { "\(Int($0))" }, help: String(format: "Lasts %.0f ms.", Double(max(0, lab.count - 1)) / Double(max(1, lab.rate)) * 1000 + Double(lab.width)))
                        brakeRow
                    }
                }
            case .sine:
                GridRow {
                    SliderRow(title: "Frequency", value: $lab.freq, range: 30...400, step: 1,
                              format: { "\(Int($0)) Hz" + ($0 > 100 ? "  audible range" : "") },
                              help: lab.freq > 100 ? (app.haptic.quiet ? "Quiet trackpad caps tones at 100 Hz, so this plays at 100." : "The glass radiates sound here.") : "Below 100 Hz the glass stays quiet.")
                    SliderRow(title: "Duration", value: $lab.duration, range: 5...80, step: 1,
                              format: { "\(Int($0)) ms" }, help: "One tone segment. 80 ms max.")
                }
                GridRow {
                    levelRow
                    Color.clear.frame(height: 1)
                }
            case .apple:
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waveform").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                        Picker("Waveform", selection: $lab.waveID) {
                            ForEach(AppleWaveform.all) { Text($0.label).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: 240)
                        Text("Played exactly as the system does at your click setting.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Color.clear.frame(height: 1)
                }
            }
        }
    }

    private var levelRow: some View {
        SliderRow(title: "Level", value: $lab.level, range: 0...lab.levelMax, step: 0.05,
                  format: { String(format: "%.2f", $0) }, help: lab.primitive == .sine ? "Tones stop at 0.8." : "Scales the amplitude. 0 to 1.")
    }

    private var brakeRow: some View {
        ToggleRow(title: "Brake", subtitle: "Follow each pulse with the same pulse reversed (negative amplitude).", isOn: $lab.brake)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            presetRow("Round 1: single pulses", HapticsLabPresetsData.round1)
            presetRow("Round 2: stronger and combined", HapticsLabPresetsData.round2)
            presetRow("Round 3: sustained energy", HapticsLabPresetsData.round3)
        }
    }

    private func presetRow(_ title: String, _ items: [LabPreset]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            FlowLayout(spacing: 6) {
                ForEach(items) { p in
                    Button { lab.apply(p) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.title).font(Theme.Font.label)
                            Text(p.detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(lab.activePreset == p.id ? Theme.accent.opacity(0.16) : Theme.raised,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(lab.activePreset == p.id ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Load into the controls. Press Play to feel it.")
                }
            }
        }
    }
}

enum HapticsLabPresetsData {
    static var round1: [LabPreset] { LabPresets.round1 }
    static var round2: [LabPreset] { LabPresets.round2 }
    static var round3: [LabPreset] { LabPresets.round3 }
}

/// Simple wrapping row layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 600, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var pts: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y)); x += sz.width + spacing; rowH = max(rowH, sz.height); maxW = max(maxW, x - spacing)
        }
        return (pts, CGSize(width: maxW, height: y + rowH))
    }
}

// MARK: - Governor

private struct GovernorReadout: View {
    private struct Snap: Equatable {
        var duty: String
        var acts: String
        var lastCall: String
        var clamped: Int
        var stalled: Bool
        var throttled: Bool
        var stallReason: String

        static func read() -> Snap {
            let g = TrackpadMotor.shared.governorStatus
            return Snap(
                duty: String(format: "%.0f%%", g.dutyPercent),
                acts: String(format: "%.0f/s", g.actsPerSecond),
                lastCall: String(format: "%.1f ms", g.lastCallMS),
                clamped: g.clampEvents,
                stalled: g.stalled,
                throttled: g.throttled,
                stallReason: g.stallReason
            )
        }
    }

    var body: some View {
        Polled(every: 0.2, read: { Snap.read() }) { g in
            Card(padding: Theme.Space.m) {
                HStack(spacing: Theme.Space.l) {
                    stat("Duty", g.duty, "limit 60%")
                    stat("Actuations", g.acts, "limit 200")
                    stat("Last call", g.lastCall, "stall at 25")
                    stat("Clamped", "\(g.clamped)", "values trimmed")
                    Spacer(minLength: 8)
                    chip(g)
                    if g.stalled { Button("Reset") { TrackpadMotor.shared.resetGovernor() }.controlSize(.small) }
                }
                if g.stalled {
                    Text(g.stallReason.isEmpty ? "Stall guard tripped. Haptics are stopped." : g.stallReason)
                        .font(Theme.Font.caption).foregroundStyle(Theme.err)
                }
            }
        }
    }

    private func stat(_ t: String, _ v: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Text(v).font(.system(size: 15, weight: .regular).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            Text(sub).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
        .frame(minWidth: 70, alignment: .leading)
    }

    private func chip(_ g: Snap) -> some View {
        let (text, color): (String, Color) = g.stalled ? ("Stalled", Theme.err) : g.throttled ? ("Throttled", Theme.warn) : ("Within limits", Theme.ok)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Theme.Font.caption.weight(.medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}
