# Notice

HapticGlow
Copyright (c) 2026 Vijay A

HapticGlow is free software under the GNU General Public License, version 3 only (GPL-3.0-only; see [LICENSE.md](LICENSE.md)), with the additional term below.

## Additional term: attribution (GPLv3 section 7(b))

As permitted by section 7(b) of the GNU General Public License version 3, the following term is added to the license of HapticGlow:

> If you convey or distribute HapticGlow, or a work based on it, in source or binary form, modified or not, you must keep this attribution notice intact and visible:
>
> **HapticGlow by Vijay A (https://github.com/VA24d/HapticGlow)**
>
> The notice must appear in three places: in the README (or the main description page) of the project that distributes the work, in a NOTICE file shipped with the source and with any binary release, and in the "About" window or equivalent legal-notices screen of the application, if it has one.
>
> You may add your own copyright line for your changes next to this notice. You may not remove it, hide it, or present the work as written solely by someone else.

This is the kind of term section 7(b) allows: preservation of specified reasonable legal notices or author attributions. It is part of the license and applies to everyone who receives HapticGlow.

Modified versions must also follow GPLv3 section 5(a): say that you changed the files and give the date.

## Third-party notices

### Key sound packs: kbsim (MIT)

The recorded mechanical key sounds in `Sounds/` come from kbsim (Mechanical Keyboard Simulator) by Thomas Lai, https://github.com/tplai/kbsim. They stay under the MIT License. The full text is in [Sounds/LICENSE-kbsim.txt](Sounds/LICENSE-kbsim.txt) and must travel with the sound files. Details are in [Sounds/CREDITS.md](Sounds/CREDITS.md).

### Code adapted from MIT-licensed projects

Parts of the source were written with reference to, or adapted from, the projects below. Their copyright lines and the MIT permission notice are reproduced here as that license requires. MIT code can be included in a GPLv3 program.

- MagicKey, Copyright (c) 2026 XiaoSong1223: Core Audio process tap, onset detector, keyboard backlight driver and state guard, light effects.
- nospeaker, Copyright (c) 2024 os6 (Cody Collier): the method for driving the Force Touch trackpad motor with synthesized waveforms.
- Thock, by kamillobinski: key layout, stereo pan law by key position, soft clipping at the output.

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Clacky (jasonzh0) and macos-design-skill (ceorkm) were read for ideas only. No code from them is included.

### Trademarks

Apple, macOS, MacBook, Force Touch and Magic Keyboard are trademarks of Apple Inc. Logitech and MX Keys are trademarks of Logitech International S.A. HapticGlow is not affiliated with or endorsed by either company. See [TERMS.md](TERMS.md).
