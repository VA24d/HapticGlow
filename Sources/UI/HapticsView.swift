// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Trackpad Haptics: mode cards, strength / cutoff / punch / pitch, test thump, live readout.
import SwiftUI

struct HapticsView: View {
    @Bindable var model = AppModel.shared

    private struct ModeInfo { let mode: HapticMode; let title: String; let blurb: String; let symbol: String }
    private let modes: [ModeInfo] = [
        .init(mode: .music, title: "Music", blurb: "Feel the song. Taps on drums, texture on bass, gentle detail on melody.", symbol: "music.note"),
        .init(mode: .movie, title: "Movie", blurb: "Big explosions and deep rumble. Stays quiet through dialogue.", symbol: "film"),
        .init(mode: .kick, title: "Kick", blurb: "A punchy thump on every kick drum.", symbol: "circle.circle"),
        .init(mode: .bass, title: "Bass", blurb: "The trackpad hums the bassline below the cutoff.", symbol: "waveform.path"),
        .init(mode: .full, title: "Pure Trackpad", blurb: "The trackpad plays the music itself, like a tiny speaker.", symbol: "speaker.wave.2"),
        .init(mode: .off, title: "Off", blurb: "No haptic output.", symbol: "nosign"),
    ]

    private var unavailableMessage: String? {
        switch model.hapticStatus {
        case .unavailable(let r), .failed(let r): return r
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Trackpad Haptics", subtitle: "Feel your music through the Force Touch trackpad.")
                if AppModel.silentLaunch && !SnapshotMode.active {
                    ScreenNotice(symbol: "speaker.slash", title: "Haptics are off for this session",
                                 message: "Haptics are off for this session (started in test mode). Relaunch HapticGlow to turn them on.",
                                 actionTitle: "Relaunch", action: { relaunchApp() })
                }
                if let msg = unavailableMessage {
                    ScreenNotice(symbol: "exclamationmark.triangle", title: "Trackpad haptics unavailable",
                                 message: msg + " The rest of the app keeps working.", actionTitle: nil, action: nil)
                }
                modeGrid
                tuning
                testCard
                HapticsLabSection()
            }
            .pageLayout()
        }
        .background(Theme.window)
    }

    /// Auto is on: Music or Movie follows the playing source.
    private var autoOn: Bool { model.haptic.autoSource && (model.haptic.mode == .music || model.haptic.mode == .movie) }

    private var modeGrid: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Mode")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: Theme.Space.m, alignment: .top)],
                      alignment: .leading, spacing: Theme.Space.m) {
                ChoiceCard(title: "Auto", subtitle: "Music or Movie by source: voice and video get Movie, music apps and music sites get Music.",
                           symbol: "wand.and.stars", selected: autoOn, minHeight: 76) {
                    withAnimation(Theme.snappy) {
                        model.haptic.autoSource = true
                        if model.haptic.mode != .music && model.haptic.mode != .movie { model.haptic.mode = .music }
                    }
                }
                ForEach(modes, id: \.mode) { m in
                    ChoiceCard(title: m.title, subtitle: m.blurb, symbol: m.symbol, selected: !autoOn && model.haptic.mode == m.mode, minHeight: 76) {
                        withAnimation(Theme.snappy) { model.haptic.autoSource = false; model.haptic.mode = m.mode }
                    }
                }
            }
            if autoOn {
                HStack(spacing: 6) {
                    Image(systemName: !model.autoStatus.playing ? "waveform" : (model.autoStatus.mode == .movie ? "film" : "music.note"))
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                    Text(model.autoStatus.line).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                if let note = model.autoStatus.note {
                    Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var tuning: some View {
        let off = model.haptic.mode == .off
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Tuning")
            Card {
                SliderRow(title: "Strength", value: $model.haptic.strength, range: 0...1,
                          help: "How hard the trackpad actuates. 100% is the maximum the hardware accepts.")
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                if model.haptic.mode == .music || autoOn {
                    Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.l) {
                        GridRow {
                            SliderRow(title: "Texture", value: $model.haptic.texture, range: 0...1,
                                      help: "How much continuous bass and sustain runs under the taps.")
                            SliderRow(title: "Detail", value: $model.haptic.detail, range: 0...1,
                                      help: "Low shows kicks only. High adds snare, hat and melody taps.")
                        }
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
                if model.haptic.mode == .movie || autoOn {
                    SliderRow(title: "Rumble", value: $model.haptic.rumble, range: 0...1,
                              help: "Intensity of deep sub-bass rumble after explosions and during heavy LFE passages.")
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SliderRow(title: "Bass cutoff", value: $model.haptic.cutoffHz, range: 40...250, step: 1,
                              format: { "\(Int($0)) Hz" }, help: "Everything below this frequency drives the trackpad.")
                    SpectrumView(height: 64)
                        .padding(8)
                        .background(Theme.window, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                }
                if model.haptic.mode == .kick || model.haptic.mode == .bass {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.l) {
                        GridRow {
                            SliderRow(title: "Punch", value: $model.haptic.punch, range: 0...1,
                                      help: "Kick: how long the thump rings. Bass: how sharp the attack is.")
                            SliderRow(title: "Pitch", value: $model.haptic.pitch, range: 0...1,
                                      help: "Kick start and end pitch. Bass octave fold target.")
                        }
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Feel").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                        Text(feelBlurb).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Picker("Feel", selection: $model.haptic.feel) {
                        ForEach(HapticFeel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                }
                ToggleRow(title: "Quiet trackpad", subtitle: "Keeps the vibration below the range the glass can turn into sound.",
                          isOn: $model.haptic.quiet)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ToggleRow(title: "Typing taps", subtitle: "A light tap on every key press.", isOn: $model.haptic.typingTaps)
                ToggleRow(title: "Use external trackpad", subtitle: "Prefer a connected Magic Trackpad over the built-in one.",
                          isOn: $model.haptic.preferExternal)
            }
            .disabled(off)
            .opacity(off ? 0.5 : 1)
        }
    }

    private var feelBlurb: String {
        switch model.haptic.feel {
        case .deep: "Low, rounded thump. Felt more than heard."
        case .punchy: "Tighter, slightly higher thump."
        case .crisp: "Short sharp taps. The most audible."
        }
    }

    private var testCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Test")
            Card {
                HStack(spacing: Theme.Space.l) {
                    TrackpadGlyph()
                        .frame(width: 160, height: 100)
                        .background(Theme.keyBase.opacity(0.0))
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(spacing: Theme.Space.s) {
                            Button("Test") { HapticEngine.shared.testThump() }
                            Text(model.haptic.quiet ? "Felt, not heard" : "May be faintly audible").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Polled(every: 0.2, read: { Int(HapticEngine.shared.actuationsPerSecond.rounded()) }) { rate in
                            HStack(spacing: 6) {
                                StatusDot(status: model.hapticStatus, size: 6)
                                Text("\(rate) actuations/s")
                                    .font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }
}
