// Selectable option cards used by the Glow, Haptics and Sounds screens.
import SwiftUI

/// Card button style: 1 pt hover lift, 0.98 press scale.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Generic choice card: optional symbol, title, subtitle and a preview area. Selected = accent hairline.
struct ChoiceCard<Preview: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var selected: Bool
    var minHeight: CGFloat = 0
    var action: () -> Void
    @ViewBuilder var preview: Preview
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                            .frame(width: 16)
                    }
                    Text(title)
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                preview
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : (hover ? Theme.hairlineStrong : Theme.hairline),
                                  lineWidth: selected ? 1 : 0.5)
            )
            .offset(y: hover && !selected ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .onHover { h in withAnimation(Theme.snappy) { hover = h } }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension ChoiceCard where Preview == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, selected: Bool, minHeight: CGFloat = 0, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, selected: selected, minHeight: minHeight, action: action) { EmptyView() }
    }
}

/// Mode lists for pickers: groups of modes in display order, always including the current value.
enum GlowModeSets {
    struct Section { let title: String; let modes: [GlowMode] }
    static func sections(_ groups: [String], including cur: GlowMode) -> [Section] {
        var out = groups.map { g in Section(title: g, modes: GlowMode.allCases.filter { GlowModeInfo.info($0).group == g }) }
        if !out.contains(where: { $0.modes.contains(cur) }) { out.append(Section(title: "Current", modes: [cur])) }
        return out
    }
}

/// Glow-mode card with a tiny live strip animating `GlowEngine.previewLevel`.
/// `badge` ("Music" / "Idle") marks the role the mode plays when automatic switching is on.
struct ModeCard: View {
    let mode: GlowMode
    let selected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        let info = GlowModeInfo.info(mode)
        ChoiceCard(title: info.title, subtitle: info.subtitle, symbol: info.symbol, selected: selected, action: action) {
            ModePreviewStrip(mode: mode)
                .frame(height: 26)
        }
        .overlay(alignment: .topTrailing) {
            if selected, let badge {
                Text(badge.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .padding(.top, 11).padding(.trailing, 28)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Rolling 3 s trace of a mode's preview level, drawn as a warm area chart.
struct ModePreviewStrip: View {
    let mode: GlowMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false
    @State private var pulse = UIPulse.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: pulse.frame(20, preview: true), paused: reduceMotion || !onScreen || !pulse.visible || mode == .off || mode == .steady)) { _ in
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4, style: .continuous), with: .color(Theme.keyBase))
                guard mode != .off else {
                    var line = Path(); line.move(to: CGPoint(x: 4, y: size.height - 3)); line.addLine(to: CGPoint(x: size.width - 4, y: size.height - 3))
                    ctx.stroke(line, with: .color(Theme.hairlineStrong), lineWidth: 1)
                    return
                }
                let now = hostNow()
                let n = mode == .lightning ? 270 : 96
                // Sleep fades over a 14 s cycle and lightning fires in sparse trains, so both need a
                // longer window than the 3 s default to look like themselves.
                let window: Double = mode == .lightning ? 9.0 : (mode == .sleep ? 14.0 : 3.0)
                let cyc = 14.0
                let sleepBase = floor(now / cyc) * cyc
                var area = Path()
                var top = Path()
                let h = size.height - 6
                area.move(to: CGPoint(x: 0, y: size.height))
                for i in 0...n {
                    let f = Double(i) / Double(n)
                    let t: Double
                    if mode == .sleep { t = sleepBase + min(f, 0.999) * window }       // whole fade, playhead moves across it
                    else { t = reduceMotion ? 1.0 + f * window : now - (1 - f) * window }
                    let v = CGFloat(max(0, min(1, GlowEngine.previewLevel(mode: mode, t: t))))
                    let p = CGPoint(x: f * size.width, y: size.height - 3 - v * h)
                    area.addLine(to: p)
                    if i == 0 { top.move(to: p) } else { top.addLine(to: p) }
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                ctx.clip(to: Path(roundedRect: rect, cornerRadius: 4, style: .continuous))
                ctx.fill(area, with: .linearGradient(Gradient(colors: [Theme.glow.opacity(0.45), Theme.glow.opacity(0.05)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(top, with: .color(Theme.glow), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                if mode == .sleep && !reduceMotion {
                    let x = CGFloat((now - sleepBase) / cyc) * size.width
                    var ph = Path(); ph.move(to: CGPoint(x: x, y: 0)); ph.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(ph, with: .color(Theme.textTertiary.opacity(0.5)), lineWidth: 0.75)
                }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .pulseConsumer()
        .accessibilityHidden(true)
    }
}
