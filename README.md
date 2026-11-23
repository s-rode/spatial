<p align="center"><img src="docs/icon.png" width="128" alt="Spatial icon: a diamond of dots, shrinking from the middle out"></p>

<h1 align="center">Spatial</h1>

<p align="center"><b>Spatial Audio for Spotify on the Mac.</b><br>
Fixed and Head Tracked from Control Center, rendered by macOS itself.</p>

<p align="center">Fork of <a href="https://github.com/matthewhamilton3141/spatial">matthewhamilton3141/spatial</a> without the self-updater; build from source.</p>

---

Spotify's Mac app doesn't get Spatial Audio. Play something and open the AirPods menu in
Control Center: Spatial Audio is unavailable. Spatial is a small menu bar app that fixes
that. Once it's running, Control Center offers **Off / Fixed / Head Tracked** for Spotify,
and macOS renders it with the same engine it uses for its own apps, including your
Personalized Spatial Audio profile if you've set one up.

## Requirements

- A Mac with Apple silicon, macOS 15 or later (built and tested on macOS 26)
- AirPods or Beats that support Spatial Audio
- The Spotify desktop app

## Install

This fork has no prebuilt releases, no installer script and no auto-updater:
build it yourself (needs only the Command Line Tools).

```sh
./build.sh
cp -R build/Spatial.app /Applications/
open /Applications/Spatial.app
```

To update: `git pull` (or merge reviewed changes from `upstream`), rebuild, copy again.
Each rebuild is ad-hoc signed, so macOS asks for System Audio Recording again.

Then:

1. Play something in Spotify. When macOS asks, allow **System Audio Recording**.
2. Open **Control Center › your AirPods › Spatial Audio** and pick **Fixed** or **Head Tracked**.

**Uninstall:** choose Quit Spatial in its menu and drag it to the Trash. To also clear its
permission and settings: `tccutil reset All com.srode.spatial; defaults delete com.srode.spatial`.

Spatial lives in the menu bar (the dotted diamond). The **Spatial Audio** switch at the top
of its menu turns it off, and Spotify goes straight back to normal: no reroute, no extra delay.

## Good to know

**Head Tracked crackles?** Head tracking makes your Mac send about 50% more Bluetooth
packets to your AirPods. In a crowded 2.4 GHz area (dorms, offices, apartments) the link
can't keep up and you hear static. **Fixed** sounds the same, minus the head tracking,
and avoids it. This is Bluetooth, not Spatial: the audio Spatial hands to macOS is clean.

**Switching modes mid-song.** Going to or from Head Tracked makes the music dip in speed
for a second or two. Your AirPods buffer about 80 ms more for head tracking, and Apple's
renderer catches up gradually rather than with a gap. Pick a mode before you press play, or
let it settle.

**Delay.** Pause and skip land about 0.15 s later than in plain Spotify. When Spatial takes
over (switching it on, or your AirPods reconnecting), the first fraction of a second is
silent while your AirPods wake up; after that the music never has to skip to catch up.

**AirPlay.** HomePods, Apple TVs and AirPlay speakers have no Spatial Audio menu, so Spatial
steps aside there and Spotify plays as usual.

**Lossless?** AirPods always receive AAC over Bluetooth, with or without Spatial. Spatial
adds no loss of its own: with Spatial Audio set to Off, what it plays matches Spotify to
within -100 dB.

**The recording indicator.** macOS may show its recording indicator while Spatial runs,
because taking another app's sound uses the same permission as recording it.

**Other apps.** `defaults write com.srode.spatial target <bundle id prefix>`, then relaunch Spatial.

## How it works

1. A Core Audio **process tap** (macOS 14.2+) takes Spotify's output and mutes it at the speakers.
2. Spatial plays the exact same samples through `AVSampleBufferAudioRenderer` with stereo
   spatialization allowed, so macOS treats it as a spatial-capable app.
3. Control Center's Spatial Audio menu now applies to it, and macOS does the rendering:
   it upmixes the stereo, places it with your HRTF, and runs head tracking from your AirPods.

Spatial does no processing of its own in this mode. It keeps about 0.3 s of audio queued
(the AirPods' Bluetooth latency plus headroom for clock jitter) and handles the renderer
reconfiguring itself when you switch modes.

The **Engine** menu also has a renderer of Spatial's own, for experimenting: **Apple
Spatial Mixer** (`AUSpatialMixer`, the renderer behind Spatialize Stereo, driven directly).
It does head tracking itself and skips the Control Center menu.

## Build from source

Needs only the Command Line Tools (no Xcode).

```sh
./build.sh run                     # build build/Spatial.app and open it
./build.sh release                 # same, plus build/Spatial.zip for a GitHub release
.build/release/Spatial --smoke     # headless self-test: engines, ring, system player
.build/release/Spatial --probe     # audio processes and the output device
open build/Spatial.app --stderr /tmp/spatial.log --args --log   # live state, once a second
```

The icon and menu bar glyph are drawn in code (`Sources/SpatialApp/Icon.swift`).

## License

MIT. Not affiliated with Spotify or Apple.
