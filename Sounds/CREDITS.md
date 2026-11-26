# Key sound sample sources and license

All `.mp3` samples in this directory come from **kbsim (Mechanical Keyboard Simulator)**, released under the **MIT License**. Redistribution (including commercial use and sublicensing) is permitted as long as the copyright notice and license text are kept. `LICENSE-kbsim.txt` in this directory contains that full text.

| Field | Detail |
|---|---|
| Upstream repository | <https://github.com/tplai/kbsim> |
| Project site | <https://kbs.im> |
| Author | Thomas Lai |
| License | MIT License (`LICENSE.md` in the upstream root; full text in `LICENSE-kbsim.txt`) |
| Sampled commit | `ba103f3b0afa9dab80447aa2e7e2ed80b6bd80e4` (2021-12-23) |
| Upstream path | `src/assets/audio/<pack>/` |

The kbsim MIT license covers the entire repository (its README lists `LICENSE.md` as "MIT license", and `src/assets/audio` is inside that tree) with no separate exception for audio assets.

## Third-party precedent

Another independent project, [nathan-fiscaletti/keyboardsounds](https://github.com/nathan-fiscaletti/keyboardsounds), also redistributes these samples and places a `LICENSE` file in each pack folder starting with:

> Audio samples from https://github.com/tplai/kbsim
>
> Copyright (c) Thomas Lai
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software ...

Other downstream projects treat the audio assets as MIT-licensed and redistributable with attribution.

## Modifications in this repository

Most original recordings are kept byte-for-byte unchanged (`GENERIC_R0` through `GENERIC_R4`, `SPACE`, `BACKSPACE`, and their corresponding `release/` files), preserving the upstream layout for traceability.

To improve how Esc and Enter sound, each pack also includes offline DSP-derived or tuned files generated from that pack's own MIT samples (44.1 kHz, mono, 128 kbps MP3):

1. `press/ESC.mp3` and `release/ESC.mp3` (added): Made from each pack's `press/GENERIC_R0.mp3` (and `release/GENERIC.mp3`) by shifting pitch down by 3.0 semitones, applying a 6 kHz low-pass filter and a -5 dB high-shelf cut above 3.5 kHz, and layering the same sample shifted down 7 semitones and low-passed at 520 Hz as a keycap cavity layer. The layer gain is raised automatically per pack until the spectral centroid is at most 60% of the original R0 and the low-frequency share is at least 12 percentage points higher than R0, followed by a +4 dB low shelf at 300 Hz and a short fade-out. If a custom or older pack lacks `ESC.mp3`, the loader falls back to `GENERIC_R0` and `release/GENERIC`.
2. `press/ENTER.mp3` and `release/ENTER.mp3` (stabilizer tuning): Made from each pack's `ENTER_orig.mp3` by shifting pitch down by 3.0 semitones, low-passing (2.2 kHz, or 3.2 kHz for clicky switches), layering the same pack's `SPACE` shifted down 3 semitones and low-passed at 480 Hz (layer gain raised per pack until the centroid is at most 60% of the original ENTER and the low-frequency share rises by at least 20 percentage points and reaches at least 15%), then adding a +4 dB low shelf at 260 Hz, damping the tail with a 50 ms time constant after 50 ms to tame stabilizer wire rattle, and matching peak level to the original ENTER.
3. `ENTER_orig.mp3` (one in `press/` and one in `release/`): The unmodified upstream `ENTER` recording before tuning, kept as a backup only. `KeySoundEngine` does not load it. Rename it over `ENTER.mp3` to restore the original recording.

Both tables below were measured uniformly after MP3 encoding and decoding, with leading silence stripped, using the first 4000 samples after attack, a Hann window, and an 8192-point FFT. Spectral centroid is computed from the power spectrum; low share is the percentage of power below 400 Hz; decay is the time for a 4 ms smoothed envelope to fall to 10% of its peak.

Press `ENTER` before -> after tuning:

| Pack | Spectral centroid (Hz) | Decay (ms) | Low share |
|---|---|---|---|
| `alpaca` | 2463 -> 1060 | 4 -> 7 | 19% -> 39% |
| `blackink` | 1548 -> 916 | 5 -> 4 | 16% -> 45% |
| `bluealps` | 1639 -> 955 | 4 -> 3 | 2% -> 23% |
| `boxnavy` | 2508 -> 1129 | 5 -> 6 | 5% -> 26% |
| `buckling` | 3128 -> 1009 | 16 -> 17 | 1% -> 23% |
| `cream` | 2525 -> 1095 | 5 -> 7 | 7% -> 30% |
| `holypanda` | 664 -> 246 | 10 -> 10 | 65% -> 84% |
| `mxblack` | 2229 -> 1209 | 5 -> 5 | 8% -> 27% |
| `mxbrown` | 1734 -> 790 | 5 -> 6 | 29% -> 50% |
| `redink` | 2054 -> 1225 | 3 -> 3 | 5% -> 26% |
| `topre` | 925 -> 553 | 9 -> 3 | 3% -> 43% |
| `turquoise` | 1403 -> 410 | 6 -> 9 | 56% -> 79% |

Press `ESC` compared with each pack's `GENERIC_R0` (R0 -> ESC):

| Pack | Spectral centroid (Hz) | Decay (ms) | Low share |
|---|---|---|---|
| `alpaca` | 1017 -> 462 | 1 -> 1 | 69% -> 84% |
| `blackink` | 1956 -> 1178 | 4 -> 5 | 20% -> 38% |
| `bluealps` | 2019 -> 904 | 6 -> 16 | 1% -> 13% |
| `boxnavy` | 2506 -> 1461 | 26 -> 21 | 21% -> 33% |
| `buckling` | 3632 -> 1854 | 19 -> 26 | 1% -> 14% |
| `cream` | 4133 -> 2076 | 2 -> 2 | 11% -> 36% |
| `holypanda` | 1992 -> 1113 | 6 -> 7 | 8% -> 36% |
| `mxblack` | 2961 -> 761 | 2 -> 2 | 15% -> 72% |
| `mxbrown` | 3085 -> 1839 | 3 -> 4 | 1% -> 20% |
| `redink` | 2706 -> 1328 | 4 -> 2 | 32% -> 55% |
| `topre` | 746 -> 418 | 16 -> 4 | 65% -> 82% |
| `turquoise` | 792 -> 347 | 3 -> 4 | 76% -> 88% |

At runtime in memory, `KeySoundEngine` performs three steps:

1. Decodes samples to Float32 PCM, resamples to the output device sample rate, trims leading silence below -60 dBFS, caps length at 0.5 s, and fades the last 2 ms.
2. Normalizes pack peak loudness to 0.8 (`min(6, max(0.5, 0.8 / peak))`) and compensates for macOS system output volume (`1 / volume`, capped at +30 dB, silent when muted or at zero).
3. Applies small random pitch and gain jitter on playback so rapid typing does not sound repetitive.

## Included and excluded packs

The sampled kbsim commit contains 13 packs. Packs are included only if they have dedicated large-key samples: `SPACE`, `ENTER`, and `BACKSPACE` in both `press/` and `release/`, plus `GENERIC_R0` through `GENERIC_R4` in `press/`. On a physical keyboard, Space, Enter, and Backspace sound distinct because of larger keycaps and stabilizers; without those samples, Space sounds identical to a letter key.

| Upstream folder | Included | Reason |
|---|---|---|
| `alpaca`, `blackink`, `bluealps`, `boxnavy`, `buckling`, `cream`, `holypanda`, `mxblack`, `mxbrown`, `redink`, `topre`, `turquoise` | Yes (12 packs) | Complete `press/` and `release/` large-key sets |
| `mxblue` | No | Only `GENERIC` samples (`press/` lacks `SPACE`, `ENTER`, `BACKSPACE`; `release/` has only `GENERIC.mp3`) |

`bluealps/release/` also contains an extra `GENERIC_long.mp3` file from upstream. It is kept to preserve the upstream directory contents, and `KeySoundEngine` ignores it (`relNames` loads only `GENERIC`, `SPACE`, `ENTER`, `BACKSPACE`, and `ESC`). It was also excluded from the loudness measurements below so an unused sample does not skew the pack gain.

## The twelve sound packs

Loudness values below were measured by decoding the 12 original loaded files per pack with `AVAudioFile` across all channels and samples, matching the app's own decoding path.

The alignment target is the loudest pack (`bluealps`, -32.00 dBFS), so `gain` is always at least 1.0 (boost only, no attenuation). Across all packs, `peak * gain` stays at or below 0.9, leaving headroom for resampling filter overshoot (+/-3%) and playback volume jitter (+/-2 dB, up to x1.259).

| Folder | UI name (tag) | Switch | Sound character | RMS (dBFS) | Peak | Gain | Peak x Gain |
|---|---|---|---|---|---|---|---|
| `boxnavy/` | Box Navy (Crisp) | Kailh Box Navy | Sharp high-frequency click | -37.05 | 0.333 | 1.79 | 0.595 |
| `bluealps/` | SKCM Blue Alps (Clacky) | Alps SKCM Blue | Metallic clack, loudest in the set | -32.00 | 0.422 | 1.00 | 0.422 |
| `buckling/` | IBM Buckling Spring (Classic) | IBM Buckling Spring | Vintage typewriter spring ring | -38.46 | 0.150 | 2.10 | 0.315 |
| `holypanda/` | Holy Panda (Thocky) | Holy Panda | Low-end thock, warm and full | -33.56 | 0.333 | 1.20 | 0.398 |
| `topre/` | Topre (Dense) | Topre electrostatic capacitive | Cushioned, soft bottom-out | -39.76 | 0.294 | 2.44 | 0.718 |
| `cream/` | NovelKeys Cream (Full) | NK Cream (POM) | Thick with a longer tail | -35.89 | 0.545 | 1.56 | 0.853 |
| `blackink/` | Gateron Ink Black (Deep) | Gateron Ink Black | Deep with a clean decay | -37.37 | 0.349 | 1.85 | 0.647 |
| `mxblack/` | Cherry MX Black (Muted) | Cherry MX Black | Muted, very little high end | -32.37 | 0.548 | 1.04 | 0.572 |
| `redink/` | Gateron Ink Red (Rounded) | Gateron Ink Red | Smooth and rounded | -34.93 | 0.415 | 1.40 | 0.581 |
| `turquoise/` | Tealios (Smooth) | Turquoise Tealios (linear) | Clean, crisp linear | -37.11 | 0.283 | 1.80 | 0.510 |
| `mxbrown/` | Cherry MX Brown (Gentle) | Cherry MX Brown | Light tactile bump, quietest click | -35.98 | 0.301 | 1.58 | 0.475 |
| `alpaca/` | Alpaca (Quiet) | JWK Alpaca (linear) | Quietest pack in the set | -40.18 | 0.242 | 2.56 | 0.620 |

Switch names come from the `caption` fields in upstream `src/features/audioModules/*.js`. Checking those captions matters: `turquoise` sounds clicky in practice, while upstream labels it Turquoise Tealios, a linear switch.

Note on the 2026-08-23 recalculation: because the alignment target tracks the loudest pack in the set, adding `bluealps` (-32.00 dBFS, 1.56 dB louder than the earlier `holypanda` reference at -33.6 dBFS) shifted every pack's gain. The three earlier gains (Box Navy 1.50, Holy Panda 1.00, MX Brown 1.32) are obsolete, and the same volume slider position became roughly 1.6 dB louder overall. Any future pack addition requires recalculating the full table.

## Files in each pack

- `press/` (9 active files plus 1 backup): `SPACE.mp3`, `ENTER.mp3`, `BACKSPACE.mp3`, `ESC.mp3`, `GENERIC_R0.mp3` through `GENERIC_R4.mp3`, and `ENTER_orig.mp3` (unused backup).
- `release/` (5 active files plus 1 backup): `SPACE.mp3`, `ENTER.mp3`, `BACKSPACE.mp3`, `ESC.mp3`, `GENERIC.mp3`, and `ENTER_orig.mp3` (unused backup). `bluealps/release/` also holds the unused `GENERIC_long.mp3`.

Except for `ESC.mp3` and the tuned `ENTER.mp3` files described above, all press and release samples are unmodified upstream recordings. Any additional folder placed inside `Sounds/` with a `press/` directory is also discovered by `KeySoundEngine` as a custom pack and peak-normalized on load.
