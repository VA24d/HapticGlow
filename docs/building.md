# Building

HapticGlow builds with the Command Line Tools alone. There is no Xcode project and no SwiftPM manifest; `build.sh` calls `swiftc` on every file under `Sources/`.

## Requirements

- Apple Silicon Mac on macOS 26 or later.
- Command Line Tools with Swift 6.2 (`xcode-select --install`). Check with `swiftc --version`.

## Targets

```sh
./build.sh typecheck   # type-check all sources, no binary (fast, use while editing)
./build.sh debug       # unoptimised build with symbols -> build/HapticGlow.app
./build.sh release     # optimised whole-module build -> build/HapticGlow.app (default)
./build.sh install     # release build, then copy to /Applications/HapticGlow.app
```

What a build does:

1. Writes a VFS overlay to `build/overlay.yaml` (see below).
2. Compiles `Sources/**/*.swift` for `arm64-apple-macos26.0` in Swift 5 language mode.
3. Assembles `build/HapticGlow.app` from `Resources/Info.plist`, `Resources/AppIcon.icns`, `LICENSE.md`, `NOTICE.md` and the `Sounds/` folder.
4. Signs the bundle (see below).

`install` also quits a running copy first so the bundle can be replaced. Pass `HAPTICGLOW_INSTALL_DIR` to install somewhere other than `/Applications`.

## The SwiftBridging workaround

The Command Line Tools ship a stale second copy of the SwiftBridging module map. With it present, every `import Foundation` fails with `redefinition of module 'SwiftBridging'`. The build writes an empty replacement and a VFS overlay that hides the stale file for the compiler, so the toolchain itself stays untouched. If you invoke `swiftc` by hand, pass `-vfsoverlay build/overlay.yaml`.

## Signing

By default the bundle is ad-hoc signed. macOS ties privacy grants (System Audio Recording, Input Monitoring) to the code signature, and an ad-hoc signature changes with every build, so grants are lost after a rebuild.

To keep grants across rebuilds, create a self-signed code-signing certificate in Keychain Access and name it in `HAPTICGLOW_SIGN_ID`. The default name is `HapticGlow Local Signing`; if a certificate with that name exists, the build uses it automatically.

```sh
HAPTICGLOW_SIGN_ID="My Dev Certificate" ./build.sh install
```

## Snapshots

The app can render its pages to PNG files without a window on screen. This is how the screenshots in the docs were made:

```sh
HAPTICGLOW_SNAPSHOT_DIR=docs/images \
HAPTICGLOW_SNAPSHOT_APPEARANCE=dark \
HAPTICGLOW_SNAPSHOT_TAG=dark \
build/HapticGlow.app/Contents/MacOS/HapticGlow --silent
```

`--silent` keeps every sound off. Use `HAPTICGLOW_SNAPSHOT_APPEARANCE=light` for the light theme.

## Command-line flags

| Flag | Effect |
|---|---|
| `--silent` | Starts with key sounds and haptics off. Use it for any run that must stay quiet. |
| `--logi-probe --test` | Probes a connected Logitech MX Keys and prints what it finds. Changes the backlight only. |

## Releases

Pushing a version tag runs the release workflow in `.github/workflows`. It builds the app, signs it, packages a DMG and attaches it to a GitHub release. With the Developer ID secrets set in the repository, it signs with that identity and notarizes the DMG; without them, the DMG is ad-hoc signed.
