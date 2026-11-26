// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// 32-band spectrum with peak-hold caps and the haptic cutoff marker.
import SwiftUI

final class SpectrumModel: @unchecked Sendable {
    var peaks = [Float](repeating: 0, count: 32)
    var shown = [Float](repeating: 0, count: 32)
    var last: Double = 0

    /// Advance smoothing + peak hold (caps fall 0.6 / s).
    func step(_ bands: SIMD32<Float>, now: Double) {
        let dt = Float(min(0.1, max(0, now - last)))
        last = now
        for i in 0..<32 {
            let v = max(0, min(1, bands[i]))
            // fast attack, ~90 ms release for the bars
            let a = v > shown[i] ? 1 : 1 - Float(exp(-Double(dt) / 0.09))
            shown[i] += (v - shown[i]) * a
            peaks[i] = max(shown[i], peaks[i] - 0.6 * dt)
        }
    }
}

struct SpectrumView: View {
    var height: CGFloat = 96
    var showsCutoff: Bool = true
    @State private var model = SpectrumModel()
    @State private var pulse = UIPulse.shared

    /// Position (0...1) of a frequency on the log axis 30 Hz – 16 kHz.
    static func position(hz: Float) -> CGFloat {
        let f = max(30, min(16000, Double(hz)))
        return CGFloat(log(f / 30) / log(16000.0 / 30.0))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: pulse.frame(60), paused: !pulse.awake)) { _ in
            Canvas { ctx, size in
                let f = FeatureBus.shared.latest()
                model.step(f.silent ? SIMD32<Float>() : f.bands, now: hostNow())
                let n = 32
                let gap: CGFloat = size.width > 200 ? 3 : 2
                let bw = max(1.5, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                let cutX = SpectrumView.position(hz: FeatureBus.shared.cutoffHz) * size.width
                let barColor = Theme.textSecondary
                let strong = Theme.textPrimary
                let capH: CGFloat = 2
                for i in 0..<n {
                    let x = CGFloat(i) * (bw + gap)
                    let h = max(2, CGFloat(model.shown[i]) * (size.height - capH - 2))
                    let r = CGRect(x: x, y: size.height - h, width: bw, height: h)
                    let below = showsCutoff && x + bw / 2 < cutX
                    ctx.fill(Path(roundedRect: r, cornerRadius: min(bw / 2, 1.5)),
                             with: .color(below ? strong.opacity(0.85) : barColor.opacity(0.55)))
                    let py = size.height - max(2, CGFloat(model.peaks[i]) * (size.height - capH - 2)) - capH - 1
                    if model.peaks[i] > 0.02 {
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: py, width: bw, height: capH), cornerRadius: 1),
                                 with: .color(barColor.opacity(0.9)))
                    }
                }
                if showsCutoff {
                    var line = Path()
                    line.move(to: CGPoint(x: cutX, y: 0)); line.addLine(to: CGPoint(x: cutX, y: size.height))
                    ctx.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if size.height >= 56 {
                        let t = ctx.resolve(Text("\(Int(FeatureBus.shared.cutoffHz)) Hz").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.accent))
                        let w = t.measure(in: size).width
                        let tx = min(max(cutX + 5, 0), size.width - w)
                        ctx.draw(t, at: CGPoint(x: tx, y: 2), anchor: .topLeading)
                    }
                }
            }
        }
        .frame(height: height)
        .pulseConsumer()
        .accessibilityLabel("Audio spectrum")
    }
}
