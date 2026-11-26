// Guided A/B feel test: five rounds, each plays two kick variants; the winner's width and body pitch
// are written into HapticConfig (punch and pitch).
import SwiftUI

struct KickVariant: Equatable {
    var width: Float      // Gaussian width, ms
    var bodyHz: Float     // sine body, quiet-safe (<= 100 Hz)
    static let amplitude: Float = 30, pulseLevel: Float = 0.8, bodyLevel: Float = 0.5, bodyMS: Float = 45
}

@MainActor @Observable
final class FeelTestModel {
    enum Phase { case intro, round, done }
    var phase: Phase = .intro
    var round = 0                   // 1...5
    var best = KickVariant(width: 6, bodyHz: 70)
    var challenger = KickVariant(width: 6, bodyHz: 70)
    var bestIsA = true
    var heardA = false
    var heardB = false
    var previous: (punch: Float, pitch: Float)?
    private var dir: [Bool: Float] = [true: 1, false: 1]   // true = width dimension, false = pitch dimension
    static let rounds = 5
    private var varyWidth: Bool { round % 2 == 1 }          // rounds 1, 3, 5 vary width; 2, 4 vary pitch

    var a: KickVariant { bestIsA ? best : challenger }
    var b: KickVariant { bestIsA ? challenger : best }

    func start() { best = KickVariant(width: 6, bodyHz: 70); dir = [true: 1, false: 1]; round = 0; next() }

    private func next() {
        round += 1
        guard round <= Self.rounds else { finish(); return }
        let step: Float = varyWidth ? [4, 2, 1][(round - 1) / 2] : [20, 10][(round - 1) / 2]
        var c = best
        let d = dir[varyWidth] ?? 1
        if varyWidth { c.width = min(12, max(3, best.width + d * step)) } else { c.bodyHz = min(100, max(50, best.bodyHz + d * step)) }
        if c == best { dir[varyWidth] = -d; if varyWidth { c.width = min(12, max(3, best.width - d * step)) } else { c.bodyHz = min(100, max(50, best.bodyHz - d * step)) } }
        challenger = c
        bestIsA = Bool.random()
        heardA = false; heardB = false
        phase = .round
    }

    func choose(a pickedA: Bool) {
        let challengerWon = (pickedA != bestIsA)
        if challengerWon { best = challenger } else { dir[varyWidth] = -(dir[varyWidth] ?? 1) }
        next()
    }

    func play(_ v: KickVariant) {
        LabPlayer.shared.run(preferExternal: AppModel.shared.haptic.preferExternal, result: { _ in }) { m, _ in
            var rc = m.pulse(amplitude: KickVariant.amplitude, widthMS: v.width, level: KickVariant.pulseLevel)
            if rc == 0 {
                LabPlayer.sleep(until: CFAbsoluteTimeGetCurrent() + 0.012)
                rc = m.sine(hz: v.bodyHz, ms: KickVariant.bodyMS, level: KickVariant.bodyLevel)
            }
            return rc
        }
    }

    /// Width 3...12 ms maps to punch 0...1; body 60...100 Hz maps to pitch 0...1 (the engine's +-25% range
    /// around the 80 Hz deep voice).
    var punch: Float { min(1, max(0, (best.width - 3) / 9)) }
    var pitch: Float { min(1, max(0, (best.bodyHz - 60) / 40)) }

    private func finish() {
        let h = AppModel.shared.haptic
        previous = (h.punch, h.pitch)
        AppModel.shared.haptic.punch = punch
        AppModel.shared.haptic.pitch = pitch
        phase = .done
    }

    func undo() {
        if let p = previous { AppModel.shared.haptic.punch = p.punch; AppModel.shared.haptic.pitch = p.pitch; previous = nil }
    }
}

struct HapticsFeelTest: View {
    @State private var t = FeelTestModel()

    var body: some View {
        Card {
            switch t.phase {
            case .intro: intro
            case .round: round
            case .done: done
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Find your kick").font(Theme.Font.title)
            Text("Five rounds. Each plays two kicks, a short pulse with a low body behind it. Rest a finger on the trackpad, play both, and pick the one that feels better. The winner sets Punch and Pitch for Kick and Music modes.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Start") { t.start() }.buttonStyle(.borderedProminent)
        }
    }

    private var round: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                Text("Round \(t.round) of \(FeelTestModel.rounds)").font(Theme.Font.label).foregroundStyle(Theme.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(1...FeelTestModel.rounds, id: \.self) { i in
                        Capsule().fill(i <= t.round ? Theme.accent : Theme.track).frame(width: 18, height: 4)
                    }
                }
            }
            HStack(spacing: Theme.Space.m) {
                option("A", isA: true)
                option("B", isA: false)
            }
            Text("Play each as often as you like. Pick once you have felt both.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func option(_ name: String, isA: Bool) -> some View {
        let heard = isA ? t.heardA : t.heardB
        return VStack(spacing: Theme.Space.s) {
            Text(name).font(Theme.Font.bigStat).foregroundStyle(Theme.textPrimary)
            Button {
                t.play(isA ? t.a : t.b)
                if isA { t.heardA = true } else { t.heardB = true }
            } label: { Label("Play \(name)", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .controlSize(.large)
            Button("\(name) feels better") { t.choose(a: isA) }
                .disabled(!(t.heardA && t.heardB))
                .controlSize(.regular)
            Text(heard ? "Played" : "Not played yet").font(Theme.Font.caption).foregroundStyle(heard ? Theme.ok : Theme.textTertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Text("Saved to your haptics settings").font(Theme.Font.title)
            }
            HStack(spacing: Theme.Space.xl) {
                result("Pulse width", String(format: "%.0f ms", t.best.width))
                result("Body pitch", "\(Int(t.best.bodyHz)) Hz")
                result("Punch", "\(Int((t.punch * 100).rounded()))%")
                result("Pitch", "\(Int((t.pitch * 100).rounded()))%")
            }
            HStack {
                Button("Play winner") { t.play(t.best) }
                Button("Run again") { t.start() }
                Button("Undo") { t.undo() }.disabled(t.previous == nil)
            }
        }
    }

    private func result(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.Font.bigStat).foregroundStyle(Theme.textPrimary)
        }
    }
}
