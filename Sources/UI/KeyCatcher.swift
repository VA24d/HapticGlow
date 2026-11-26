// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Focusable key sink for in-app typing (Try It, Typing Practice).
//
// SwiftUI views do not handle keyDown, so AppKit walks the responder chain, finds nobody, and plays
// NSBeep for every key. KeyCatcher becomes first responder and consumes keyDown/keyUp/flagsChanged
// (never calls super), so there is no beep. Key sounds and glow still come from the system-wide
// KeyMonitor tap; `onKey` only gives the view the typed text for its own logic.
// Command shortcuts are left to the main menu (performKeyEquivalent returns false).
import SwiftUI
import AppKit

struct KeyCatcherEvent {
    let keyCode: UInt16
    let characters: String      // as typed, with shift applied ("" for non-text keys)
    let modifiers: NSEvent.ModifierFlags
    let isRepeat: Bool
}

struct KeyCatcher: NSViewRepresentable {
    /// Becomes first responder while true (and again whenever the window becomes key).
    var active: Bool = true
    var onKey: (KeyCatcherEvent) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Bump to take focus again (for example after a click on the surrounding view).
    var refocus: Int = 0

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onKey = onKey; v.onFocusChange = onFocusChange; v.wantsActive = active
        v.lastRefocus = refocus
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onKey = onKey; v.onFocusChange = onFocusChange
        if v.wantsActive != active { v.wantsActive = active }
        if v.lastRefocus != refocus { v.lastRefocus = refocus; v.takeFocus() }
    }

    final class CatcherView: NSView {
        var onKey: (KeyCatcherEvent) -> Void = { _ in }
        var onFocusChange: (Bool) -> Void = { _ in }
        var wantsActive = true {
            didSet {
                if wantsActive { claimFocus() }
                else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            }
        }
        var lastRefocus = 0
        private var keyObs: NSObjectProtocol?

        override var acceptsFirstResponder: Bool { wantsActive }
        override func becomeFirstResponder() -> Bool { onFocusChange(true); return true }
        override func resignFirstResponder() -> Bool { onFocusChange(false); return true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let o = keyObs { NotificationCenter.default.removeObserver(o); keyObs = nil }
            guard let w = window else { return }
            keyObs = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w,
                                                            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.claimFocus() }
            }
            claimFocus()
        }

        /// Explicit request: takes focus even from a text field.
        func takeFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsActive, let w = self.window, w.firstResponder !== self else { return }
                w.makeFirstResponder(self)
            }
        }

        func claimFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsActive, let w = self.window, w.firstResponder !== self else { return }
                if w.firstResponder is NSTextView { return }   // don't steal focus from a text field
                w.makeFirstResponder(self)
            }
        }

        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

        override func keyDown(with event: NSEvent) {
            onKey(KeyCatcherEvent(keyCode: event.keyCode, characters: event.characters ?? "",
                                  modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
                                  isRepeat: event.isARepeat))
            // Swallowed: not calling super is what prevents the beep.
        }
        override func keyUp(with event: NSEvent) {}
        override func flagsChanged(with event: NSEvent) {}
        override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

        deinit { if let o = keyObs { NotificationCenter.default.removeObserver(o) } }
    }
}
