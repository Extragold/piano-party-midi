# Piano Party MIDI prototype

Native Windows and macOS companions for a real MIDI keyboard. This is a prototype;
its OS-keyboard transport still needs testing against Roblox with physical hardware.
Codec tests do not establish real latency or that every OS key pulse reaches Roblox.

## Windows: try it

1. Stop and restart Studio Play after Rojo sync.
2. In the game's Layout dropdown, choose **MIDI**. This also enters Perform mode.
3. Open `dist/windows/PianoPartyMidi.exe`. Keep its DLL and JSON files alongside it.
   This build uses the .NET 10 Windows Desktop runtime, already installed on the
   development PC. It is not a self-contained installer.
4. Select your MIDI input device and leave the velocity curve on Linear initially.
5. Enable **Send to Piano Party**, then focus Roblox/Studio's game window.
6. Wait for audio loading; try one note softly, the same note hard, a chord,
   a repeated note, and sustain at several pedal positions. Inspect the MIDI
   connection status in the Layout dropdown and diagnostics in Settings.
   You can also click **Test C4 in 3 seconds**, then focus Roblox. It sends two C4
   strikes at velocities 40 and 115 without needing a physical keyboard.
7. Disable sending before switching to QWERTY or opening other Studio editing tools.

If you were testing a recording, reselect MIDI in the dropdown to reset the live
sampler before testing the physical keyboard. Simultaneous recorded and physical
MIDI performance has not been validated in this prototype.

## Mac: build and test

The source is `macos/main.swift`, using AppKit, CoreMIDI and CoreGraphics, with no
third-party packages. It has not been compiled on this Windows development host.
On a Mac with Xcode Command Line Tools installed:

```sh
cd macos
bash build.sh
open '../dist/macos/Piano Party MIDI.app'
```

Use **Allow keyboard events**, then enable this app in macOS Privacy & Security →
Accessibility. Select MIDI in the game, choose a device, enable sending and focus
Roblox. The build script signs locally for development; public distribution still
needs a Developer ID signature and notarization. Build separately on Apple Silicon
and Intel Macs if distributing both architectures.

## What is carried

- All 88 piano pitches (MIDI 21–108), note-on/note-off and 16 channels.
- Velocity 1–127. F7 does not override physical keyboard velocity in MIDI mode.
- CC64 sustain, including intermediate pedal values; CC67 soft pedal.
- A heartbeat; loss of the connection clears only the external player's input.
- MIDI velocity-zero note-ons are note-offs; repeated same-channel notes release
  their earlier strike before retriggering. Sostenuto and aftertouch are not added.

Live sampling loads one velocity-80 layer for each pitch gradually, then warms up
recently requested velocity layers. A ready layer at the same pitch is used with
the actual velocity gain if the exact layer is not loaded yet. Initial strikes
can still be unavailable before audio is ready. This is not full-bank preloading.

## Transport and limits

The app reads the OS MIDI API and emits normal keyboard down/up events only while
Roblox is the foreground app. It does not inject code into Roblox or access its
memory. F13 starts a packet; F1–F12 encode base-12 digits; F15 commits; F14 is
external-input panic. Each packet contains kind, channel, pitch, velocity and a
checksum. These function keys are reserved while MIDI layout is selected; use the
on-screen Lock button and Settings panic button instead of F6/F7/F8 in that mode.

Keep the game focused and out of text entry/menus while sending. A checksum rejects
malformed packets, but cannot recover a dropped note: hardware/OS testing is
essential. Windows queues reject old messages instead of playing them late. The
receiver releases external notes and pedals after 1.25 seconds without packets.

Roblox cannot directly read USB MIDI from an experience. Its WebSocket API is
Studio-only, not a published-game transport:
https://devforum.roblox.com/t/websockets-support-in-studio-is-now-available/4021932

## Builds and checks

```powershell
cd windows
dotnet publish -c Release --no-self-contained -o ../dist/windows
```

Windows build verified. Windows encoder output was decoded by the actual Luau
protocol; 14,080 pitch/channel/velocity packets, corruption recovery, partial
pedal, soft pedal and independent timeout cleanup were checked. Real MIDI hardware,
Roblox key-event delivery, end-to-end latency and the Mac build remain unverified.
