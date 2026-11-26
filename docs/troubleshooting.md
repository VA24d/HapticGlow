# Troubleshooting

The log is at `~/Library/Logs/HapticGlow/hapticglow.log`. It records engine status, capture state, backlight write timing and dimming state. The Dashboard and Audio Input pages show the same status live.

## The first launch is blocked

Release builds are ad-hoc signed and not notarized. Right-click the app, choose Open, then Open again. If that does not work:

```sh
xattr -dr com.apple.quarantine /Applications/HapticGlow.app
```

## Permissions

**Key sounds or typing glow do nothing.** Open the Permissions page. If Input Monitoring is not granted, press Request Access, switch HapticGlow on in System Settings, then press Relaunch. macOS applies Input Monitoring only after an app restarts.

**The grant is on but nothing works after a rebuild.** This only affects builds you compile yourself. An ad-hoc signature changes on every build, so macOS treats each build as a new app. Remove HapticGlow from the Input Monitoring list with the minus button and add it again, or sign your builds with a stable certificate (see [building](building.md#signing)).

**No audio capture.** Check System Audio Recording in Privacy & Security. If HapticGlow is already listed and enabled there, the grant belongs to an older build. Remove it with the minus button and reopen the app. If System Audio Tap keeps failing, switch the source on the Audio Input page to Screen Capture Audio and grant Screen Recording.

**Auto haptics misses a browser tab.** When Auto haptics runs while a browser plays audio, macOS asks once for Automation permission so HapticGlow can read the active tab's URL. If you declined, toggle the browser on under Privacy & Security, Automation, or let Auto fall back to its speech-versus-music check.

## The keyboard does not light up

- Check that glow is enabled and a mode other than Off is selected.
- The Mac needs a backlit built-in keyboard. For an external keyboard, use the Logitech link.
- The keyboard has one backlight channel for all keys. Per-key lighting exists only in the on-screen keyboard.
- Backlight control uses a private macOS framework, so a macOS update can break it. If the log shows write errors, open an issue with your macOS version.
- If the backlight stays stuck at a level after a crash, press Restore keyboard backlight in Settings.

**The light never reaches full brightness.** Leave Keep keyboard lit on in the Glow page. Without it, macOS dims the backlight after five seconds without typing.

## Light and haptics feel out of step with the music

The Mac captures audio before the speakers or headphones play it. Open Settings, keep Auto (device latency) on, and use Fine-tune to move the effects later if the light leads the sound. Bluetooth headphones add 150 to 250 ms and need a larger offset than speakers.

## The trackpad stays silent

- Check that Haptics is on and the mode is not Off. A banner on the Haptics page warns you if no trackpad is found.
- Haptics need a Force Touch trackpad. For a Magic Trackpad, turn on Use external trackpad.
- In System Settings, Trackpad, turn on Force Click and haptic feedback. Set the click strength to anything above silent.
- Haptics pause for a moment when the safety governor trips. It caps actuations per second, duty and run length. After repeated driver errors, it halts haptics until you toggle them off and on, and notes the halt in the log.

The trackpad uses a private framework (MultitouchSupport) and can also break with a macOS update.

## Music sounds muffled after using a call or a headset mic

When a Bluetooth headset opens its microphone, macOS drops it to the 8 or 16 kHz call profile. Everything you hear turns thin and quiet. HapticGlow notices the drop and writes `call mode on` to the log. The headset triggers this drop, not the app. Close the app using the headset microphone, or pick another input device in System Settings, Sound, to restore the normal profile.

## Key sounds arrive late or sound wrong

- Bluetooth headphones delay sound by about 150 to 250 ms. Software cannot remove that link delay, so use wired headphones or speakers for typing.
- On built-in speakers, turn on Speaker tuning to bring back the low end.
- Spatial placement is off by default on Bluetooth for the same reason.

## Logitech MX Keys

- The link talks HID++ to the MX Keys family over Bluetooth LE. Opening the device needs Input Monitoring.
- Turn on Logitech keyboard on the Glow page and check its status line.
- To probe the keyboard from a terminal, run `open -n -W build/HapticGlow.app --args --logi-probe --test`. It changes only the backlight.
- The keyboard needs to be awake. Press a key first.

## Still stuck

Open an issue at https://github.com/VA24d/HapticGlow/issues with your macOS version, Mac model and the last 50 lines of the log. Read the log before posting it: it can contain device names, the last 4 characters of a keyboard serial number and file or app names. Remove anything you do not want public.
