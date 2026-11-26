// Practice visuals: WPM-over-time chart and the per-key heatmap (read-only use of KeyLayout.caps).
import SwiftUI

enum PracticeKeyMap {
    /// Character -> ANSI virtual keycode (Carbon kVK_*). Shifted symbols map to their base key.
    static let codes: [Character: UInt16] = {
        var d: [Character: UInt16] = [:]
        let letters: [(Character, UInt16)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (c, k) in letters { d[c] = k }
        let sym: [(String, UInt16)] = [("1!", 18), ("2@", 19), ("3#", 20), ("4$", 21), ("6^", 22), ("5%", 23), ("=+", 24),
            ("9(", 25), ("7&", 26), ("-_", 27), ("8*", 28), ("0)", 29), ("]}", 30), ("[{", 33), ("'\"", 39), (";:", 41),
            ("\\|", 42), (",<", 43), ("/?", 44), (".>", 47), (" ", 49), ("`~", 50)]
        for (chars, k) in sym { for c in chars { d[c] = k } }
        return d
    }()

    /// Aggregate stats per keycap keycode.
    static func byKeyCode(_ stats: [String: KeyStat]) -> [UInt16: KeyStat] {
        var out: [UInt16: KeyStat] = [:]
        for (k, s) in stats {
            guard let c = k.first, k.count == 1, let code = codes[c] else { continue }
            var a = out[code] ?? KeyStat()
            a.count += s.count; a.misses += s.misses; a.latSum += s.latSum; a.latSamples += s.latSamples
            out[code] = a
        }
        return out
    }
}

struct KeyHeatmap: View {
    enum Metric: String, CaseIterable, Identifiable { case errors = "Errors", speed = "Speed"; var id: String { rawValue } }
    let stats: [String: KeyStat]
    var metric: Metric

    var body: some View {
        let byCode = PracticeKeyMap.byKeyCode(stats)
        let lats = byCode.values.compactMap { $0.count >= AdaptiveGenerator.minSamples ? $0.meanLatency : nil }
        let fast = lats.min() ?? 100, slow = max(lats.max() ?? 300, fast + 40)
        Canvas { ctx, size in
            let unit = min(size.width / KeyLayout.size.width, size.height / KeyLayout.size.height)
            let ox = (size.width - KeyLayout.size.width * unit) / 2
            let gap: CGFloat = 0.06
            for cap in KeyLayout.caps {
                let r = CGRect(x: ox + (cap.rect.minX + gap) * unit, y: (cap.rect.minY + gap) * unit,
                               width: (cap.rect.width - 2 * gap) * unit, height: (cap.rect.height - 2 * gap) * unit)
                let path = Path(roundedRect: r, cornerRadius: unit * 0.14, style: .continuous)
                ctx.fill(path, with: .color(Theme.keyOff))
                var t = 0.0, hasData = false
                if let s = byCode[cap.keyCode], s.count >= AdaptiveGenerator.minSamples {
                    hasData = true
                    switch metric {
                    case .errors: t = min(1, s.missRate / 0.25)
                    case .speed: t = s.meanLatency.map { min(1, max(0, ($0 - fast) / (slow - fast))) } ?? 0
                    }
                    let tint = metric == .errors ? Theme.err : Theme.warn
                    // Data keys get a faint base so "no data" and "fine" differ.
                    ctx.fill(path, with: .color(Theme.ok.opacity(0.16)))
                    ctx.fill(path, with: .color(tint.opacity(0.08 + 0.82 * t)))
                }
                ctx.stroke(path, with: .color(Theme.hairline), lineWidth: 0.5)
                if cap.kind == .generic || cap.kind == .space, !cap.label.isEmpty, cap.keyCode != 0xFFFF {
                    let text = Text(cap.label.lowercased()).font(.system(size: max(8, unit * 0.34), weight: .medium, design: .monospaced))
                        .foregroundStyle(hasData ? Theme.textPrimary : Theme.textTertiary)
                    ctx.draw(text, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
                }
            }
        }
        .aspectRatio(KeyLayout.size.width / KeyLayout.size.height, contentMode: .fit)
        .accessibilityLabel("Keyboard heatmap of \(metric.rawValue.lowercased()) per key")
    }
}

struct WPMChart: View {
    let wpm: [Double]
    let raw: [Double]
    let errors: [Int]

    var body: some View {
        Canvas { ctx, size in
            let left: CGFloat = 30, bottom: CGFloat = 18, top: CGFloat = 6, right: CGFloat = 6
            let plot = CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
            let ymax = max(20, ((max(wpm.max() ?? 0, raw.max() ?? 0) / 20).rounded(.up)) * 20)
            func pt(_ i: Int, _ v: Double, _ n: Int) -> CGPoint {
                CGPoint(x: plot.minX + (n <= 1 ? 0 : plot.width * Double(i) / Double(n - 1)),
                        y: plot.maxY - plot.height * min(1, max(0, v / ymax)))
            }
            // grid + y labels
            for k in 0...2 {
                let v = ymax * Double(k) / 2
                let y = plot.maxY - plot.height * Double(k) / 2
                var p = Path(); p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
                ctx.stroke(p, with: .color(Theme.hairline), lineWidth: 0.5)
                ctx.draw(Text("\(Int(v))").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
            let n = wpm.count
            let step = max(1, Int((Double(n) / 6).rounded(.up)))
            for i in stride(from: 0, to: n, by: step) {
                ctx.draw(Text("\(i + 1)s").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: pt(i, 0, n).x, y: plot.maxY + 4), anchor: .top)
            }
            func curve(_ v: [Double]) -> Path {
                var p = Path()
                guard v.count > 1 else { if let f = v.first { p.move(to: pt(0, f, 1)); p.addLine(to: CGPoint(x: plot.maxX, y: pt(0, f, 1).y)) }; return p }
                let pts = v.indices.map { pt($0, v[$0], v.count) }
                p.move(to: pts[0])
                for i in 1..<pts.count {
                    let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                    p.addQuadCurve(to: mid, control: pts[i - 1])
                }
                p.addLine(to: pts.last!)
                return p
            }
            ctx.stroke(curve(raw), with: .color(Theme.textTertiary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3]))
            ctx.stroke(curve(wpm), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            for (i, e) in errors.enumerated() where e > 0 && i < n {
                let p = pt(i, wpm[i], n)
                let r: CGFloat = 3
                var x = Path()
                x.move(to: CGPoint(x: p.x - r, y: p.y - r)); x.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
                x.move(to: CGPoint(x: p.x - r, y: p.y + r)); x.addLine(to: CGPoint(x: p.x + r, y: p.y - r))
                ctx.stroke(x, with: .color(Theme.err), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .accessibilityLabel("Words per minute over time")
    }
}
