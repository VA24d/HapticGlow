// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Keyboard shortcut cheat sheet (⌘/).
import SwiftUI

struct CheatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Control", [
            ("Start or stop", "⌘↩"),
            ("Previous / next glow mode", "⌘[  ⌘]"),
            ("Raise / lower ceiling", "⌘⌥↑  ⌘⌥↓"),
            ("Mute key sounds", "⌘M"),
            ("Toggle haptics", "⌘⇧H"),
        ]),
        ("Navigate", [
            ("Dashboard", "⌘1"), ("Typing Practice", "⌘2"), ("Keyboard Glow", "⌘3"), ("Trackpad Haptics", "⌘4"),
            ("Key Sounds", "⌘5"), ("Audio Input", "⌘6"), ("Permissions", "⌘7"), ("Settings", "⌘8"),
        ]),
        ("App", [
            ("Settings", "⌘,"), ("Keyboard shortcuts", "⌘/"), ("Minimize window", "⌘⌥M"), ("Quit", "⌘Q"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Keyboard Shortcuts").font(Theme.Font.title)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(g.0)
                        ForEach(g.1, id: \.0) { row in
                            HStack(spacing: 8) {
                                Text(row.0).font(Theme.Font.body).foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 8)
                                KbdChip(row.1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(Theme.window)
    }
}
