// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// First-run sheet: 3 steps with progress dots.
import SwiftUI

struct OnboardingView: View {
    @State private var model = AppModel.shared
    /// Dev snapshotter hook: first step shown by the next presentation.
    nonisolated(unsafe) static var initialStep = 0
    @State private var step = OnboardingView.initialStep
    private let steps = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: audioStep
                default: keysStep
                }
            }
            .id(step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32).padding(.top, 32)

            footer
        }
        .frame(width: 520, height: 500)
        .background(Theme.window)
        .animation(Theme.snappy, value: step)
        .interactiveDismissDisabled()
    }

    // MARK: Steps

    private var intro: some View {
        stepLayout(symbol: "keyboard", title: "Welcome to HapticGlow",
                   body: "Your keyboard backlight and trackpad react to the music playing on your Mac, and your keys get satisfying sounds.") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Audio is analysed in memory only. It is never recorded and never sent anywhere.", systemImage: "lock")
                Label("Needs two permissions, which the next steps walk through.", systemImage: "checkmark.shield")
            }
            .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            .labelStyle(.titleAndIcon)
        }
    }

    private var audioStep: some View {
        stepLayout(symbol: "waveform", title: "Hear your Mac's audio",
                   body: "HapticGlow captures the Mac's output digitally, the way screen recorders do. No virtual device, Multi-Output setup or microphone. macOS asks once for permission.") {
            VStack(alignment: .leading, spacing: 12) {
                AudioSourceCard(compact: true)
                HStack(spacing: 10) {
                    StatusChip(text: model.audioState.label, status: model.audioState.engineStatus)
                    if model.audioState == .idleNoAudio || model.audioState == .active {
                        Text(model.audioState == .active ? "Hearing audio." : "Play some music to see it respond.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Open Settings") { model.openPrivacySettings(model.audioSource == .processTap ? .audioCapture : .screenRecording) }
                    Button("Check Again") { model.start(); model.refreshStatuses() }
                }.controlSize(.small)
                if model.audioState == .needsPermission {
                    Text("Allow HapticGlow in Privacy & Security, then come back.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var keysStep: some View {
        stepLayout(symbol: "keyboard", title: "Input Monitoring",
                   body: "Needed for typing glow and key sounds. Only key position and timing are used, never what you type.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusChip(text: model.hasInputMonitoring ? "Granted" : "Not granted",
                               status: model.hasInputMonitoring ? .running : .needsPermission("Input Monitoring"))
                    KeyIndicator()
                }
                HStack(spacing: 8) {
                    Button("Request Access") { model.requestInputMonitoring() }
                    Button("Open Settings") { model.openPrivacySettings(.inputMonitoring) }
                }.controlSize(.small)
                HStack(spacing: 8) {
                    Text("macOS may need a relaunch before it starts seeing keys.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Button("Relaunch") { relaunchApp() }.controlSize(.small).buttonStyle(.link)
                }
            }
        }
    }

    private func stepLayout<C: View>(symbol: String, title: String, body: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textPrimary)
                .frame(height: 32)
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            Text(body).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content().padding(.top, 4)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Skip") { model.completeOnboarding() }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).font(Theme.Font.caption)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Circle().fill(i == step ? Theme.textPrimary : Theme.hairlineStrong).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(steps)")
            Spacer()
            HStack(spacing: 8) {
                if step > 0 { Button("Back") { step -= 1 } }
                if step < steps - 1 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { model.completeOnboarding() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// Lights up when KeyBus delivers a key event; lets people confirm Input Monitoring works.
private struct KeyIndicator: View {
    private struct Snap: Equatable { var seen: Bool; var lit: Bool }

    var body: some View {
        Polled(every: 0.1, read: {
            let last = KeyBus.shared.lastEvent()
            return Snap(seen: last != nil, lit: last.map { hostNow() - $0.time < 0.4 } ?? false)
        }) { s in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                    .fill(s.lit ? Theme.glow : Theme.track)
                    .frame(width: 22, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
                    .animation(.easeOut(duration: 0.2), value: s.lit)
                    .accessibilityHidden(true)
                Text(!s.seen ? "Press any key" : (s.lit ? "Key detected" : "Press another key"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
