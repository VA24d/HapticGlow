# Contributing

Thanks for looking at HapticGlow. Small, focused pull requests are easiest to review.

## Build

You need macOS 26 or later on Apple Silicon and the Swift 6.2 Command Line Tools. Xcode and SwiftPM are not used.

```sh
./build.sh typecheck   # fast compile check, no app bundle
./build.sh release     # builds build/HapticGlow.app
```

`./build.sh install` copies the app to /Applications. Quit a running copy first. Use `--silent` when you launch a development build so key sounds stay quiet while you test.

## Before you open a pull request

- `./build.sh typecheck` passes.
- You tried the area you changed. For the MX Keys code, `open -n -W build/HapticGlow.app --args --logi-probe --test` runs the probe.
- You did not lower key-sound latency, audio-to-light sync or onset detection quality. Changes to the trackpad motor must keep the safety governor in force.
- No new network code. The app has none, and [PRIVACY.md](PRIVACY.md) depends on that.

## Style

- Plain Swift 6.2, strict concurrency. Match the surrounding code.
- Keep code on the realtime audio and haptic paths free of allocation, locks you do not need, and logging. Logging helpers say which calls are safe.
- Comments explain why, not what. Names over comments where a name will do.
- UI text is sentence case and says what the control does.

## Pull request flow

1. Fork, branch from `main`, make the change.
2. Open a pull request and describe what changed and why. Mention how you checked it.
3. Reviews are required before merging into `main`; CI must pass.

There is no contributor license agreement and no sign-off line. By submitting a change you agree that it is licensed under the project license (GPL-3.0 with the term in [NOTICE.md](NOTICE.md)).

## Attribution rule

Keep the notice "HapticGlow by Vijay A (https://github.com/VA24d/HapticGlow)" in the README, NOTICE and About window of anything you distribute, as [NOTICE.md](NOTICE.md) requires. Add your own copyright line for your changes if you like, but do not remove the original. Keep third-party licenses (for example `Sounds/LICENSE-kbsim.txt`) with the files they cover.

Please do not add automated-tool attribution lines, co-author trailers or similar credit to commits, code or docs. Credit goes to the people who wrote the change.

## Reporting problems

Bugs and ideas go in GitHub issues. Security problems go through the private process in [SECURITY.md](SECURITY.md).
