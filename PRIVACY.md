# Privacy

HapticGlow runs entirely on your Mac.

- **No network access.** The source has no networking code (no URLSession, sockets or web requests). The only URLs it opens are System Settings privacy panes (`x-apple.systempreferences:`), so you can grant permissions, and the project's GitHub link in the About section of Settings, which opens in your browser only when you click it.
- **No telemetry, analytics or crash reporting.** Nothing is collected and there is no account.
- **Audio is never recorded or sent.** The system audio tap reads buffers in memory to compute levels, beats and onsets, then discards them. No audio is written to disk.
- **The microphone is used only when you press Measure with microphone.** In the sync fine-tune panel that button records about 6 seconds from the built-in microphone while music you already have playing comes out of the speakers, and compares it with what the Mac sent to them to find the real delay. The recording lives in memory only, is analysed and discarded, and is never written to disk or sent anywhere. HapticGlow asks for microphone access at that moment and not before, never changes your default input device, and plays no sound of its own.
- **Keystrokes are not stored.** Key events are used to trigger a sound and a light pulse. The app keeps no record of what you type. Input Monitoring is needed for this and nothing else.

- **Song details stay on your Mac.** When Apple Music or Spotify plays, HapticGlow reads the song name, artist, album and genre that the player announces to other apps on your Mac. They are shown in the app and used to pick tuning. They are never sent anywhere, and the only song details written to disk are the title and artist of songs you choose to save tuning for. HapticGlow never controls playback.

## What is stored

On your Mac only:

- **Preferences** in UserDefaults (domain `com.hapticglow.mac`, file in `~/Library/Preferences`): effect, haptic and sound settings, audio source, menu bar visibility, onboarding state, the last backlight brightness known to be good, and typing practice options (word count, time limit).
- **Saved song tuning** in UserDefaults (key `songTunings.v1`): for up to 500 songs you chose to remember, the song's title and artist, an identifier from the player, and the haptic and glow settings you saved. The oldest unused songs are dropped first. *Forget All* in Settings clears it.
- **Typing practice history** in UserDefaults (key `practice.v1`): up to 200 past sessions with results, personal bests, and per-key timing and miss counts. This covers only the practice words HapticGlow showed you. It is not recorded from normal typing.
- **Logitech MX Keys backlight settings** in UserDefaults (keys starting `logiOriginal.`, `logiMaxDuration.` and `logiLastSerial.`): your saved backlight configuration, so it can be restored. The keys include the keyboard's product name and, when it reports one, its serial number.
- **A backlight snapshot** at `~/Library/Application Support/HapticGlow/backlight-snapshot.json`: the keyboard backlight state from before HapticGlow changed it, used to restore it after a crash or force quit.
- **A log file** at `~/Library/Logs/HapticGlow/hapticglow.log`. It records app events such as device detection, permission state and errors. It is plain text, you can read or delete it at any time, and it is not uploaded. Log lines show only the last 4 characters of a keyboard serial number.

To remove everything HapticGlow keeps, quit the app, delete it, then run:

```sh
defaults delete com.hapticglow.mac
rm -rf ~/Library/Logs/HapticGlow "$HOME/Library/Application Support/HapticGlow"
```

## Permissions

See the Permissions section of the [README](README.md) for what each one is used for.

## Changes

If a future version adds any network feature, this file will say so and it will be off by default.
