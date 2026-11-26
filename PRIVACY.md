# Privacy

HapticGlow runs entirely on your Mac.

- **No network access.** The source has no networking code (no URLSession, sockets or web requests). The only URLs it opens are System Settings privacy panes (`x-apple.systempreferences:`), so you can grant permissions.
- **No telemetry, analytics or crash reporting.** Nothing is collected and there is no account.
- **Audio is never recorded or sent.** The system audio tap reads buffers in memory to compute levels, beats and onsets, then discards them. No audio is written to disk.
- **Keystrokes are not stored.** Key events are used to trigger a sound and a light pulse. The app keeps no record of what you type. Input Monitoring is needed for this and nothing else.

## What is stored

On your Mac only:

- **Preferences** in UserDefaults (`~/Library/Preferences`, bundle preferences for HapticGlow): effect, haptic and sound settings, audio source, menu bar visibility, onboarding state, the last backlight brightness known to be good, and typing practice options (word count, time limit).
- **A log file** at `~/Library/Logs/HapticGlow/hapticglow.log`. It records app events such as device detection, permission state and errors. It is plain text, you can read or delete it at any time, and it is not uploaded.

Deleting the app and those two locations removes everything HapticGlow keeps.

## Permissions

See the Permissions section of the [README](README.md) for what each one is used for.

## Changes

If a future version adds any network feature, this file will say so and it will be off by default.
