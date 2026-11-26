# About window attribution

[NOTICE.md](../NOTICE.md) requires the attribution notice to appear in the application's About window or legal-notices screen. The app shows the name "HapticGlow" in the sidebar (`Sources/UI/SidebarView.swift`) and the menu bar popover (`Sources/UI/MenuBarView.swift`) but has no About screen yet.

Put the notice in the About panel and keep it when forking:

- Text: `HapticGlow by Vijay A` with a link to `https://github.com/VA24d/HapticGlow`.
- Second line: `Licensed under GPL-3.0. Key sounds from kbsim by Thomas Lai (MIT).`
- Placement: the standard About panel (`NSApp.orderFrontStandardAboutPanel`) takes a `credits` attributed string, which is the natural place. A footer in the Settings window works too.
- Also set `NSHumanReadableCopyright` in `Resources/Info.plist` to `Copyright 2026 Vijay A. GPL-3.0. HapticGlow by Vijay A (https://github.com/VA24d/HapticGlow). Key sounds: kbsim by Thomas Lai (MIT).`

Forks add their own line below this one and leave it in place.
