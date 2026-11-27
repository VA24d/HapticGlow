// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Now-playing rows for the Dashboard and the menu bar panel. Plain text only, and only while a song plays.
import SwiftUI

/// The playing song's remember / forget control, shared by both rows.
private struct SongTuningButton: View {
    @State private var np = NowPlaying.shared
    var body: some View {
        if np.canRemember {
            Button(np.isRemembered ? "Update saved tuning" : "Remember for this song") { np.remember() }
                .controlSize(.small)
                .help("Keep the haptic and glow changes you made during this song, and use them whenever it plays again.")
        } else if np.isRemembered {
            Button("Forget") { np.forget() }
                .controlSize(.small)
                .help("Stop using the tuning saved for this song.")
        }
    }
}

@MainActor private func noteText(_ np: NowPlaying) -> String {
    if let n = np.appliedNote { return n }
    return np.canRemember ? "You changed the tuning during this song" : (np.track?.album ?? "")
}

/// Dashboard card.
struct NowPlayingCard: View {
    @State private var np = NowPlaying.shared

    var body: some View {
        if let t = np.track {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text([t.artist, noteText(np)].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.m)
                SongTuningButton()
            }
            .padding(Theme.Space.m)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(t.title)\(t.artist.isEmpty ? "" : " by \(t.artist)")")
        }
    }
}

/// Menu bar panel module. Same module surface as its neighbours.
struct NowPlayingMenuRow: View {
    @State private var np = NowPlaying.shared

    var body: some View {
        if let t = np.track {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(t.artist.isEmpty ? noteText(np) : t.artist)
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                if np.canRemember || np.isRemembered {
                    HStack { Spacer(); SongTuningButton() }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(t.title)\(t.artist.isEmpty ? "" : " by \(t.artist)")")
        }
    }
}
