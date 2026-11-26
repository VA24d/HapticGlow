# Security policy

## Supported versions

Only the latest release gets security fixes. HapticGlow targets macOS 26 and later on Apple Silicon.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Older releases | No, please update |

## Reporting a vulnerability

Report it privately. Do not open a public issue.

1. Go to the [Security tab](https://github.com/VA24d/HapticGlow/security) of the repository.
2. Choose **Report a vulnerability** (GitHub Security Advisories).
3. Describe what you found, the macOS version, the HapticGlow version, and steps to reproduce it.

You will get a first reply within 7 days. This is a one-person project, so a fix can take longer, but I will tell you where it stands and credit you in the release notes if you want that.

## In scope

- Misuse of the permissions HapticGlow asks for: System Audio Recording (system audio tap), Input Monitoring (key events for key sounds), and Screen Recording (fallback audio path).
- Anything that makes HapticGlow read keystrokes, audio or other data beyond what [PRIVACY.md](PRIVACY.md) says, or send it anywhere.
- HID access: the app talks to a Logitech MX Keys over HID++ and to the trackpad motor. Bugs that write unintended reports to other HID devices.
- Memory safety or privilege problems in the app, its build script, or the release workflow (for example a way to tamper with a signed release).
- Log files that expose sensitive data.

## Out of scope

- Problems that need an attacker who already controls your account or has granted themselves the permissions above.
- Hardware wear or damage from heavy haptic use (see [TERMS.md](TERMS.md)); report those as normal issues.
- Vulnerabilities in macOS, Logitech firmware, or third-party apps.
- The ad-hoc signed, not notarized status of releases: it is documented in the README.
