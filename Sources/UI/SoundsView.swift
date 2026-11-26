// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Key Sounds: pack picker, mix controls, interactive mini keyboard, latency readout.
import SwiftUI

struct SoundsView: View {
    @Bindable var model = AppModel.shared
    @Bindable var spatialSettings = SpatialSettings.shared
    @State private var tapped: (label: String, pan: Float, depth: Float)?
    @State private var pins = SoundPinStore.shared
    @State private var trigger: KeyboardVisualizer.KeyTrigger?
    @State private var focused = false
    @State private var seq = 0
    @State private var refocus = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Key Sounds", subtitle: "Mechanical keyboard sounds for every key you press, placed by position.")
                if AppModel.silentLaunch && !SnapshotMode.active {
                    ScreenNotice(symbol: "speaker.slash", title: "Key sounds are off for this session",
                                 message: "Key sounds are off for this session (started in test mode). Relaunch HapticGlow to turn them on.",
                                 actionTitle: "Relaunch", action: { relaunchApp() })
                }
                packs
                output
                mix
                keyboardCard
            }
            .pageLayout()
        }
        .background(Theme.window)
    }

    private var packs: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Sound pack")
            if model.packs.isEmpty {
                ScreenNotice(symbol: "speaker.slash", title: "No sound packs found",
                             message: "Reinstall HapticGlow to restore the bundled packs.", actionTitle: nil, action: nil)
            } else {
                let pinned = model.packs.filter { pins.isPinned($0.id) }
                let others = model.packs.filter { !pins.isPinned($0.id) }
                if !pinned.isEmpty {
                    Text("Favourites").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    packGrid(pinned)
                    if !others.isEmpty {
                        Text("All packs").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                            .padding(.top, Theme.Space.xs)
                    }
                }
                if !others.isEmpty { packGrid(others) }
            }
        }
    }

    private func packGrid(_ list: [SoundPack]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: Theme.Space.m, alignment: .top)],
                  alignment: .leading, spacing: Theme.Space.m) {
            ForEach(list) { pack in
                ChoiceCard(title: pack.name, subtitle: pack.character, symbol: "keyboard",
                           selected: model.sound.packID == pack.id) {
                    withAnimation(Theme.snappy) { model.sound.packID = pack.id }
                    KeySoundEngine.shared.preview(keyCode: 0x31)
                }
                .overlay(alignment: .topTrailing) { pinButton(pack) }
            }
        }
    }

    private func pinButton(_ pack: SoundPack) -> some View {
        let on = pins.isPinned(pack.id)
        return Button {
            withAnimation(Theme.snappy) { pins.toggle(pack.id) }
        } label: {
            Image(systemName: on ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.textTertiary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4).padding(.trailing, model.sound.packID == pack.id ? 26 : 4)
        .help(on ? "Unpin \(pack.name)" : "Pin \(pack.name) to Favourites")
        .accessibilityLabel(on ? "Unpin \(pack.name)" : "Pin \(pack.name)")
    }

    /// Current output, the Spatial toggle and the Bluetooth call-mode notice.
    private var output: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Output")
            Card {
                Polled(every: 0.5, read: { KeySoundEngine.shared.route }) { route in
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: 8) {
                            Image(systemName: route.output.kind == .builtInSpeakers ? "laptopcomputer" :
                                    (route.output.kind == .bluetooth || route.output.kind == .wiredHeadphones) ? "headphones" : "hifispeaker")
                                .foregroundStyle(Theme.textSecondary)
                            Text(route.summary).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        if let note = route.note, spatialSettings.enabled, !route.spatial {
                            Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        if route.output.callMode { callModeNotice(route.output) }
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ToggleRow(title: "Spatial key sounds",
                          subtitle: "Place each click at its key's position. Speakers get a wide front stage, wired headphones get binaural 3D.",
                          isOn: $spatialSettings.enabled)
                ToggleRow(title: "Spatial on Bluetooth",
                          subtitle: "Off by default: Bluetooth already adds delay, so clicks stay plain stereo.",
                          isOn: $spatialSettings.onBluetooth)
                ToggleRow(title: "Speaker tuning",
                          subtitle: "On the built-in speakers, add low-end harmonics and a soft limiter so thock stays audible.",
                          isOn: $spatialSettings.speakerTuning)
            }
        }
    }

    private func callModeNotice(_ out: OutputRouteInfo) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            Text("Headphones are in call mode (\(Int(out.sampleRate / 1000)) kHz). Another app is using the headset mic.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Use MacBook microphone") { OutputRoute.useBuiltInMicrophone() }
                .controlSize(.small)
        }
        .padding(10)
        .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var mix: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Mix")
            Card {
                SliderRow(title: "Volume", value: $model.sound.volume, range: 0...1, help: "Overall level of the key sounds.")
                Grid(alignment: .topLeading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.l) {
                    GridRow {
                        SliderRow(title: "Spatial spread", value: $model.sound.spatial, range: 0...1,
                                  help: "How far left and right the keys sit. Applies to plain stereo and spatial.")
                        SliderRow(title: "Pitch variation", value: $model.sound.pitchVariation, range: 0...1,
                                  help: "Random detune so repeats don't sound identical.")
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                ToggleRow(title: "Release sounds", subtitle: "Play the key-up sound too.", isOn: $model.sound.releaseSounds)
                ToggleRow(title: "Modifier sounds", subtitle: "Shift, Control, Option and Command make sounds.", isOn: $model.sound.modifierSounds)
            }
        }
    }

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Try it")
            Card {
                KeyboardVisualizer(style: .sounds, interactive: true, onKey: { cap in
                    KeySoundEngine.shared.preview(keyCode: cap.keyCode)
                    note(cap)
                }, onTap: { refocus &+= 1 }, trigger: trigger)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .background(
                    // Swallows real key presses while this page is visible so macOS never beeps.
                    // Sound and glow come from the system-wide key monitor, so nothing is played twice.
                    KeyCatcher(active: true, onKey: { e in
                        if let cap = KeyLayout.caps.first(where: { $0.keyCode == e.keyCode }) {
                            seq += 1
                            trigger = .init(keyCode: e.keyCode, seq: seq)
                            note(cap)
                        }
                    }, onFocusChange: { v in DispatchQueue.main.async { focused = v } }, refocus: refocus)
                )
                .animation(Theme.snappy, value: focused)
                Text(focused ? "Type on your keyboard to try it." : "Type to try it. Click here to focus.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
                    .onTapGesture { refocus &+= 1 }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(spacing: Theme.Space.l) {
                    PanReadout(tapped: tapped)
                    Spacer()
                    Polled(every: 0.25, read: {
                        [Int((KeySoundEngine.shared.lastLatencyMs * 10).rounded()),
                         KeySoundEngine.shared.outputBufferFrames]
                    }) { v in
                        let lat = Double(v[0]) / 10
                        let buf = v[1]
                        HStack(spacing: Theme.Space.l) {
                            readout("Latency", lat > 0 ? String(format: "%.1f ms", lat) : "–")
                            readout("Buffer", buf > 0 ? "\(buf) frames" : "–")
                        }
                    }
                }
            }
        }
    }

    private func note(_ cap: KeyCap) {
        let x = Float(cap.rect.midX / KeyLayout.size.width)
        let y = Float(cap.rect.midY / KeyLayout.size.height)   // 0 = back (function row), 1 = front (space row)
        tapped = (cap.label.isEmpty ? "Key" : cap.label, KeySoundEngine.effectivePan(keyCode: cap.keyCode, x: x, spatial: model.sound.spatial), (0.5 - y) * 2)
    }

    private func readout(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Last key and where it sits in the stereo field, e.g. "J · 8% right · 20% back".
private struct PanReadout: View {
    let tapped: (label: String, pan: Float, depth: Float)?
    var body: some View {
        if let t = tapped {
            HStack(spacing: 8) {
                Text(t.label)
                    .font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 26)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.track, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(panText(t.pan) + " \u{00B7} " + depthText(t.depth))
                    .font(Theme.Font.numeral).foregroundStyle(Theme.textSecondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.track).frame(width: 64, height: 34)
                    Circle().fill(Theme.glow).frame(width: 8, height: 8)
                        .offset(x: CGFloat(t.pan) * 28, y: -CGFloat(t.depth) * 13)
                }
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5).frame(width: 64, height: 34))
                .accessibilityHidden(true)
            }
            .animation(Theme.snappy, value: t.pan)
            .animation(Theme.snappy, value: t.depth)
        } else {
            Text("Last key and its position (left/right, front/back) show here.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }
    private func depthText(_ d: Float) -> String {
        let v = Int((abs(d) * 100).rounded())
        return v < 3 ? "mid row" : (d > 0 ? "\(v)% back on the board" : "\(v)% front on the board")
    }
    private func panText(_ p: Float) -> String {
        let v = Int((abs(p) * 100).rounded())
        return v < 3 ? "centre" : (p < 0 ? "\(v)% left" : "\(v)% right")
    }
}
