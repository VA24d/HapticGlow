# How it works

HapticGlow separates capture, analysis, rendering, and UI across dedicated threads connected by lock-free or short-lock buses. The main actor runs only SwiftUI views, persistence, and lifecycle control; audio, haptics, lighting, and key sounds never wait on the main thread.

## Architecture overview

```
SystemAudioTap / ScreenCaptureAudio (audio IO thread)
        |
        v  mono Float32 buffers
  AudioAnalyzer (256-sample hop, FFT + onset + BPM)
        |
        v  AudioFeatures
    FeatureBus (1536-frame ring + synchronous listeners)
     /      |       \
    v       v        v
GlowEngine  |    HapticEngine (MusicPlanner / MoviePlanner / Kick / Bass / Full)
  |         |        |
  |         v        v
  |   LogitechBacklight   TrackpadMotor (MotorGovernor -> MultitouchSupport)
  v
BacklightDriver (CoreBrightness)

KeyMonitor (CGEventTap thread) -> KeyBus -> KeySoundEngine (SPSC ring -> AVAudioSourceNode)
                                        \-> GlowEngine (key flash / typing modes)
                                        \-> HapticEngine (typing taps)
```

## Audio capture and analysis

Two backends implement `AudioCapture` in [AppModel.swift](../Sources/App/AppModel.swift):

- `SystemAudioTap` ([SystemAudioTap.swift](../Sources/Audio/SystemAudioTap.swift)) creates a Core Audio process tap (`AudioHardwareCreateProcessTap`) paired with a private aggregate device. It excludes HapticGlow's own PID so key sounds do not feed back into the analyzer. It also watches default output device changes and runs a watchdog that separates real stream stalls from normal silence.
- `ScreenCaptureAudio` ([ScreenCaptureAudio.swift](../Sources/Audio/ScreenCaptureAudio.swift)) uses ScreenCaptureKit audio capture with a 2x2 px, 1 fps dummy display stream (discarded). This acts as a fallback when the user selects Screen Capture Audio.

Both backends pass mono Float32 samples on their own audio queues into `AudioAnalyzer.shared.process(_:count:sampleRate:)` ([AudioAnalyzer.swift](../Sources/Audio/AudioAnalyzer.swift)).

`AnalyzerCore` preallocates all FFT and ring buffers so the hot path does no heap allocation. Every 256-sample hop (about 5.3 ms at 48 kHz), it:

1. Updates a per-sample low-pass onset envelope and backtracks along a sample ring to estimate the attack start time (`lastOnsetTime`).
2. Runs a 2048-sample Hann-windowed FFT to compute 5 coarse frequency bands (`sub`, `bass`, `lowMid`, `mid`, `high`) and 32 log-spaced spectrum bands. It also finds the energy below `FeatureBus.cutoffHz`, the dominant bass pitch, and the two strongest mid peaks.
3. Runs a 512-sample short FFT with a tail-light window to detect snare and hi-hat transients (`snareOnset`, `hatOnset`), spectral `centroid`, and full-band spectral `flux`.
4. Estimates tempo (`bpm`) and `beatPhase` from an 8-second onset-impulse autocorrelation refined by a least-squares beat-grid fit.

Each hop publishes an `AudioFeatures` struct to `FeatureBus.shared` ([Contracts.swift](../Sources/Core/Contracts.swift)). `FeatureBus` appends the struct to a 1536-frame ring buffer (about 6 seconds of history) and calls registered listeners synchronously on the analysis thread.

## Sync delay

System audio capture sees audio before the speakers or Bluetooth headphones play it. Built-in speakers add 10 to 30 ms of delay, while Bluetooth A2DP headphones add 150 to 250 ms.

`OutputLatency` ([OutputLatency.swift](../Sources/Audio/OutputLatency.swift)) watches Core Audio latency properties on the default output device (`kAudioDevicePropertyLatency`, `kAudioDevicePropertySafetyOffset`, `kAudioDevicePropertyBufferFrameSize`, and stream latency) and writes the total seconds to `SyncClock.shared.outputLatency`. `SyncClock.shared.delay` returns `max(0, (autoLatency ? outputLatency : 0) + userOffset)`.

Music-driven consumers hold their output to match that delay:

- `GlowEngine` schedules detected beats at `lastOnsetTime + SyncClock.delay` and reads continuous levels via `FeatureBus.shared.delayed(delay)`.
- `HapticEngine` schedules discrete taps at `captureTime + SyncClock.delay - HapticTuning.motorLatency` and reads continuous levels from its `FeatureDelayLine`.
- `LogitechBacklight` sends HID++ updates early by its measured Bluetooth write latency (`leadSeconds`), so the external keyboard moves with the built-in one.

Key-driven effects (key flash, typing glow, typing taps, and key sounds) respond directly to physical presses and skip `SyncClock.delay`.

## Keyboard glow and MX Keys

`GlowEngine` ([GlowEngine.swift](../Sources/Light/GlowEngine.swift)) runs a dedicated render thread at 240 Hz in music modes and 60 Hz in ambient modes. Power management via [PowerState.swift](../Sources/Core/PowerState.swift) scales those rates down on battery or in Low Power Mode. All curves evaluate in perceived brightness (`0...1`) and map to hardware light through one power curve so fades look uniform. When `autoSwitch` is active, the engine crossfades between the music mode and idle ambient mode over roughly one second. In Heartbeat mode with `heartFollowsCPU` enabled, `SystemLoad` ([SystemLoad.swift](../Sources/Core/SystemLoad.swift)) polls `host_processor_info` at 1 Hz and maps CPU load to 50-140 BPM.

`BacklightDriver` ([BacklightDriver.swift](../Sources/Light/BacklightDriver.swift)) opens Apple's private `CoreBrightness` framework via `dlopen` (`KeyboardBrightnessClient`). Before changing the backlight, it saves the current brightness, auto-brightness setting, and idle-dim timer to memory and to `Application Support/HapticGlow/backlight-snapshot.json`. It installs `SIGINT` and `SIGTERM` handlers so the backlight is restored on stop, quit, or crash recovery. Fast updates use `setBrightness:fadeSpeed:0 commit:NO` across PWM duties 54 to 336. Transitions through the 6-54 dark band issue feed-forward plain writes so hardware ramps smoothly instead of snapping off.

When enabled, `LogitechBacklight` ([LogitechBacklight.swift](../Sources/Light/LogitechBacklight.swift)) discovers MX Keys keyboards over IOKit HID (`usagePage 0xFF43`, `usage 0x0202`). It drives HID++ 2.0 feature `BACKLIGHT2` (`0x1982`) with 20-byte `0x11` reports (device index `0xFF` over Bluetooth LE) and restores the keyboard's original backlight configuration on exit.

## Trackpad haptics and safety governor

`HapticEngine` ([HapticEngine.swift](../Sources/Haptics/HapticEngine.swift)) runs a `.userInteractive` scheduler thread that drives the Force Touch actuator through five active modes:

- `MusicPlanner` ([MusicPlanner.swift](../Sources/Haptics/MusicPlanner.swift)) layers kick, snare, hat, bass texture, and sparse melody in priority order (`kick > snare > hat > texture > melody`). It keeps distinct taps separated and ducks texture around transients.
- `MoviePlanner` ([MoviePlanner.swift](../Sources/Haptics/MoviePlanner.swift)) tracks a slow adaptive LFE baseline to fire strong impact pulses and sub-bass rumble while staying quiet during dialogue and light score.
- `AudioSourceMonitor` ([AudioSourceMonitor.swift](../Sources/Audio/AudioSourceMonitor.swift)) runs when Auto source mode is active with Music or Movie selected. It watches Core Audio process output and classifies app bundle IDs and audible browser tab URLs (via Apple Events). For unrecognized apps, it falls back to periodic speech-versus-music scoring with hysteresis.
- `kick`, `bass`, and `full` (two strongest spectral peaks) execute directly in `HapticEngine`.

Every actuation call passes through `TrackpadMotor` ([TrackpadMotor.swift](../Sources/Haptics/TrackpadMotor.swift)), which loads `MultitouchSupport` via `dlopen`. Inside `TrackpadMotor`'s lock, `MotorGovernor` enforces hard limits (`MotorLimits`) that no planner or UI control can bypass:

- Argument clamps: `maxGaussian` of 48 (`|amplitude| * level`), pulse width 2 to 12 ms, `maxToneLevel` of 0.8, max tone length 80 ms, and tone frequency 30 to 400 Hz (capped at 100 Hz when `quiet` is enabled).
- Rate and duty caps: at most 200 actuations per second, and at most 60% active actuating time across any sliding 1-second window.
- Continuous run protection: high-energy runs (`|amp| * level >= 24` or tone level >= 0.4) taper amplitude down to 40% between 1500 ms and 2000 ms, then force a 300 ms rest (`restMS`).
- Stall guard: 2 consecutive actuator calls taking over 25 ms (or any single call over 100 ms), or 3 consecutive non-zero return codes, trip `stalled` and halt all actuation until `resetGovernor()` is called.

## Key monitor and key sounds

`KeyMonitor` ([KeyMonitor.swift](../Sources/Keys/KeyMonitor.swift)) installs a listen-only `CGEventTap` on a dedicated `.userInteractive` run-loop thread (requiring Input Monitoring permission). It normalizes Apple Silicon special function-row and `NX_SYSDEFINED` keycodes. From `KeyLayout` ([KeyLayout.swift](../Sources/Keys/KeyLayout.swift)), it looks up key type, row, and normalized `(x, y)` coordinates, then publishes `KeyEvent` values synchronously to `KeyBus`.

`KeySoundEngine` ([KeySoundEngine.swift](../Sources/Keys/KeySoundEngine.swift)) decodes the 12 MP3 packs in `Sounds/` (plus custom folders that contain a `press/` directory) into contiguous Float32 slabs at the output sample rate. It trims leading silence below -60 dBFS and normalizes each pack's peak level to 0.8. On each `KeyEvent` from `KeyBus`:

1. The tap-thread listener picks the sample slot (`GENERIC_R0` through `GENERIC_R4`, `SPACE`, `ENTER`, `BACKSPACE`, `ESC`, or release equivalents). It adds slight random pitch and +/-1.2 dB gain jitter, applies macOS system volume compensation (`1 / volume`, capped at +30 dB), and pushes an `RTEvent` into a lock-free SPSC ring buffer.
2. An always-on `AVAudioEngine` `AVAudioSourceNode` render callback drains the ring and mixes up to 40 voices with linear interpolation. It applies optional built-in speaker bass enhancement (`Biquad`) and Thock-style soft clipping (`softClip` above 0.7), with zero allocations, locks, or logging on the render thread.
3. `OutputRoute` ([OutputRoute.swift](../Sources/Audio/OutputRoute.swift)) monitors output device kind and Bluetooth HFP call-mode drops (8 or 16 kHz). That lets `KeySoundEngine` switch automatically between plain stereo panning and multi-lane `AVAudioEnvironmentNode` spatial rendering (`SpatialChain`).

## File map

| Path | Purpose |
|---|---|
| `Sources/App/HapticGlowApp.swift` | Process entry (`--probe-audio`, `--logi-probe`, `--silent`), window/menu bar scenes, commands, `Snapshotter` |
| `Sources/App/AppModel.swift` | Observable app state, UserDefaults persistence, engine lifecycle, permissions |
| `Sources/Core/Contracts.swift` | Shared structs (`AudioFeatures`, `KeyEvent`, configs), `SyncClock`, `FeatureBus`, `KeyBus`, `HapticBus`, `Log` |
| `Sources/Core/PowerState.swift` | Battery and Low Power Mode observer (`IOPowerSources`) |
| `Sources/Core/SystemLoad.swift` | 1 Hz CPU usage sampler for Heartbeat mode |
| `Sources/Audio/SystemAudioTap.swift` | Core Audio process tap + private aggregate device + stall watchdog |
| `Sources/Audio/ScreenCaptureAudio.swift` | ScreenCaptureKit fallback audio capture |
| `Sources/Audio/AudioAnalyzer.swift` | Hop-based vDSP FFT, bands, onset/snare/hat detection, pitch, BPM tracker |
| `Sources/Audio/AudioSourceMonitor.swift` | Auto haptic source classifier (bundle IDs, browser Apple Events, speech-vs-music fallback) |
| `Sources/Audio/OutputLatency.swift` | Core Audio default output latency measurement |
| `Sources/Audio/OutputRoute.swift` | Output device kind/call-mode watcher and `SpatialChain` builder |
| `Sources/Light/BacklightDriver.swift` | `CoreBrightness` `dlopen` driver, dark-band glide, state snapshot and crash recovery |
| `Sources/Light/GlowEngine.swift` | 240/60 Hz perceived-lightness renderer for all 15 `GlowMode` presets |
| `Sources/Light/LogitechBacklight.swift` | HID++ 2.0 `BACKLIGHT2` (`0x1982`) driver for Logitech MX Keys |
| `Sources/Haptics/TrackpadMotor.swift` | `MultitouchSupport` `dlopen` driver and `MotorGovernor` safety limiter |
| `Sources/Haptics/HapticEngine.swift` | Realtime scheduler thread and Kick / Bass / Pure Trackpad synthesis |
| `Sources/Haptics/MusicPlanner.swift` | Multi-layer music haptic planner (kick, snare, hat, texture, melody) |
| `Sources/Haptics/MoviePlanner.swift` | Cinema LFE impact and sub-bass rumble planner |
| `Sources/Keys/KeyLayout.swift` | MacBook Pro / MacBook Air ANSI key geometry and model detection |
| `Sources/Keys/KeyMonitor.swift` | Listen-only `CGEventTap` thread and F-row/aux keycode mapping |
| `Sources/Keys/KeySoundEngine.swift` | SPSC ring buffer, voice mixer, speaker tuning, soft clipper, pack loader |
| `Sources/Practice/` | Typing practice engine, text corpus, session metrics, charts, and history store |
| `Sources/UI/` | SwiftUI pages (`DashboardView`, `GlowView`, `HapticsView`, `SoundsView`, `PracticeView`, `AudioInputView`, `PermissionsView`, `SettingsView`, `MenuBarView`, `HapticsLabView`, `OnboardingView`, `CheatSheetView`) |
| `Resources/` | `Info.plist`, entitlements, app icon (`AppIcon-1024.png`, `AppIcon.icns`) |
| `Sounds/` | 12 MIT-licensed mechanical switch packs from `kbsim` plus `CREDITS.md` and `LICENSE-kbsim.txt` |
| `scripts/make_dmg.sh` | Packages `HapticGlow.app`, `/Applications` symlink, `LICENSE.md`, and `NOTICE.md` into a compressed DMG |
| `build.sh` | Single-command `swiftc` build, bundle assembly, and signing script |
