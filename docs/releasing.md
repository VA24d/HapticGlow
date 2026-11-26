# Releasing HapticGlow

Releases are built by `.github/workflows/release.yml` when a tag starting with `v` is pushed. The workflow builds the app, signs it, wraps it in a DMG, and attaches the versioned DMG, a fixed-name `HapticGlow.dmg` copy, and a SHA-256 file for each to a GitHub Release with generated notes.

## Cut a release

1. Set the version in `Resources/Info.plist`: `CFBundleShortVersionString` (for example `2.1`) and bump `CFBundleVersion`.
2. Open a pull request with the change and merge it into `main` once CI is green.
3. Tag the merge commit and push the tag:

   ```sh
   git checkout main && git pull
   git tag v2.1
   git push origin v2.1
   ```

4. Watch the Release workflow. The first step fails the run if the tag (without the `v`) differs from `CFBundleShortVersionString`, so a mismatch shows up immediately.
5. Open the new release page, read the generated notes, and edit them if needed.

To try the packaging locally without a tag:

```sh
./build.sh release
scripts/make_dmg.sh              # writes build/HapticGlow-<version>.dmg
```

## Signing modes

Without any secrets, the workflow signs the app ad-hoc. Gatekeeper warns on first launch; the README explains the right-click > Open step and the `xattr` alternative. macOS also asks again for System Audio Recording and Input Monitoring after each update, because an ad-hoc signature changes with every build.

With a Developer ID certificate, the same workflow signs with the hardened runtime and `Resources/HapticGlow.entitlements`, signs the DMG, notarizes it with Apple, and staples the ticket. Users then open the app without a warning.

## Add the signing secrets later

You need a paid Apple Developer Program membership.

1. In Xcode or on developer.apple.com, create a **Developer ID Application** certificate.
2. In Keychain Access, export the certificate with its private key as a `.p12` file with a password.
3. Encode it: `base64 -i DeveloperID.p12 | pbcopy`.
4. Create an app-specific password at appleid.apple.com for notarization.
5. Add these under Settings > Secrets and variables > Actions:

   | Secret | Value |
   | --- | --- |
   | `MACOS_CERT_P12` | The base64 text from step 3 |
   | `MACOS_CERT_PASSWORD` | The `.p12` password |
   | `MACOS_SIGN_ID` | Certificate name, for example `Developer ID Application: Your Name (TEAMID)` |
   | `NOTARY_APPLE_ID` | Apple ID email used for notarization |
   | `NOTARY_TEAM_ID` | Ten-character team ID |
   | `NOTARY_PASSWORD` | The app-specific password from step 4 |

The signing steps run only when `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` and `MACOS_SIGN_ID` are all set and non-empty; if any is missing the app is signed ad-hoc. The notarization steps run when the three `NOTARY_*` secrets also exist. Nothing else in the workflow changes.

## Branch protection on `main`

These settings are applied to `main` (Settings > Branches, or a repository ruleset):

- Require a pull request before merging.
- Require 1 approving review, from a code owner (`.github/CODEOWNERS`).
- Dismiss stale approvals when new commits are pushed.
- Require the `Typecheck and build` status check from the CI workflow, with the branch up to date.
- Require linear history (squash or rebase merges only).
- Block force pushes and branch deletion.

The owner is the only code owner, so the owner's own pull requests need either a second reviewer or an admin bypass. Keep the bypass for the owner so solo work stays possible.

## CodeQL

CodeQL is not set up. Its Swift analysis traces an Xcode or SwiftPM build, and this project builds with a single `swiftc` call, which the CodeQL autobuilder cannot trace reliably. Revisit it if the project moves to an Xcode project or a Swift package.
