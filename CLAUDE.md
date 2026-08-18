# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS toy for driving DMX lights through an **Enttec DMX USB Pro**: a SwiftUI app (`DMXControl`),
a scripting CLI (`dmxcli`), and a shared library (`DMXCore`). Pure SwiftPM, no Xcode project,
Command Line Tools are enough (macOS 14+, Swift 5.10+, Swift 5 language mode).

Hardware on this machine (not derivable from code): the widget enumerates as
`/dev/cu.usbserial-EN538648` (FTDI 0403:6001, Apple's built-in FTDI driver, FW 1.44); the light is an
**amaran Halo 300x** (bi-color, 2700–6500 K) at DMX address 1 via amaran's USB-C→5-pin adapter.
The Halo's DMX channel maps are in `docs/amaran-dmx-profile-spec-v1.1.pdf` and summarized in README.md.

## Commands

```
./build.sh                # swift build (debug) → .build/debug/{DMXControl,dmxcli}
./build.sh run [flags]    # build + launch the app. Flags: --connect (auto-connect),
                          #   --high-speed, --demo (preset Halo 60%/4500K), --screenshot PATH (render window to PNG, quit)
./build.sh cli <args>     # build + run dmxcli
./build.sh app            # release build → dist/DMXControl.app (ad-hoc signed, icon baked in) and open it
./build.sh icon           # re-render docs/icon.png
./build.sh clean          # rm -rf .build dist
swift build --product dmxcli        # rebuild just the CLI
```

There is no test target. Hardware smoke tests are the CLI:

```
dmxcli list | info                          # ports / widget serial, firmware, break/MAB/refresh
dmxcli halo 50 3200 [--profile 2] [--addr N] # Halo: intensity %, CCT K, hold 2 s
dmxcli set 1=255 2=64 --hold 5 | black       # raw channels
dmxcli params --rate 0|40                    # widget refresh (0 = as fast as possible) — persists in the widget!
dmxcli bench --channels 24 --fps 750 --seconds 10   # paced stream; TIOCOUTQ + write() blocking = backpressure
dmxcli drain / latency                        # burst-then-close timing / burst-then-get-params round trip
```

Only one process can hold the port (`TIOCEXCL`): stop the app before running `dmxcli`, and vice
versa. Wrap anything that talks to the widget in a timeout from scripts —
`perl -e 'alarm 20; exec @ARGV' -- .build/debug/dmxcli …` — a wedged port op otherwise hangs the shell.
After moving/renaming the repo directory, `rm -rf .build` (SwiftPM's module cache bakes in absolute paths).
Regenerate the README screenshot with `./build.sh run --connect --demo --screenshot docs/screenshot.png`
then `sips -Z 1400 docs/screenshot.png`.

## Architecture

**`Sources/DMXCore`** (library, everything `public`)
- `SerialPort` — raw POSIX serial (open/termios/write/read, `TIOCEXCL`, `TIOCOUTQ`). Opens at
  **3 Mbaud via `IOSSIOSPEED`** (ioctl number hand-defined; the macro doesn't import). See gotchas.
- `EnttecPro` — pure functions for the widget protocol: framing `7E label lenLSB lenMSB data… E7`,
  label 6 = send DMX (start code + channels, `dmxPacket(universe:channels:)`, min 24 channels),
  labels 3/10 = get params/serial, label 4 = set params. Also the **timing model**
  `dmxLineTime(channels:)` (break + MAB + (1+n)×44 µs) that pacing is built on.
- `AppIcon` — the icon drawn in CoreGraphics (1024-pt reference canvas, Apple's 824/1024 body +
  185.4 radius grid). One source for two consumers: the app sets it as the live dock icon at launch
  (a bare SwiftPM executable has no bundle to carry one), and `dmxcli icon --iconset` feeds
  `iconutil` in `build.sh app`. Change the drawing, then `./build.sh icon` to refresh the README copy.
- `AmaranHalo` — `HaloProfile` (Profile 1 = 3ch CCT Universal, Profile 2 = 5ch CCT) and `HaloState`
  (intensity %, CCT K, ±green, strobe, CCT+) → `encode(profile:)` bytes.

**`Sources/DMXControl`** (SwiftUI app)
- `DMXController` (`@MainActor ObservableObject`, singleton `.shared`) is the heart. It owns the
  512-byte universe (`channels`, published, main-actor) and a lock-guarded copy (`frame`) that a
  `DispatchSourceTimer` on `ioQueue` snapshots and writes to the widget every tick. Convention:
  main-actor state is `@Published`; state shared with `ioQueue` is `nonisolated(unsafe)` and touched
  only under `lock`; ioQueue-only state is `nonisolated(unsafe)` with a comment saying so. UI updates
  from the timer are batched to ~5 Hz via `DispatchQueue.main.async`.
  - Two streaming modes. **Normal**: full 512-channel frames at `frameRate` (default 40 = the widget's
    own refresh rate). **High speed** (`highSpeed`): sends label 4 to set widget refresh 0, shrinks
    frames to the highest in-use channel (min 24, with a 2 s high-water-mark hold so a channel that
    drops to 0 is still transmitted), and re-arms the timer at `dmxLineTime × 1.1` per tick.
    Widget params are restored on disconnect/quit (`originalParams`).
  - `shutdownSync()` is called from `AppDelegate.applicationShouldTerminate` (also on
    SIGINT/SIGTERM/SIGHUP): stop timer → restore params → flush + close, synchronously on `ioQueue`,
    so the port is free before the process exits.
- Views: `HaloPanelView` holds its own `HaloState` and pushes encoded bytes into the universe at its
  start address on every change (one-way; the raw grid doesn't feed back). `ChannelGridView` edits
  channels directly. `DebugView` shows the last wire packet (hex), mode/frame/pacing, and a change log.
- `DMXControlApp`/`AppDelegate`: because this runs as a bare SwiftPM executable (no bundle), the
  delegate sets `NSApp.setActivationPolicy(.regular)` and activates; it also parses the launch flags.

**`Sources/dmxcli/main.swift`** — flat command switch over the same DMXCore APIs; every command
opens the port itself. Add new experiments here first; they're cheap and don't need the GUI.

## Hard-won gotchas (all measured — see README "Timing & gotchas")

- **Keep the 3 Mbaud setting.** The Pro's data path ignores baud, but macOS's serial driver computes
  its close()/drain wait as bytes-written ÷ baud. At 115200 a session that wrote 60 KB makes `close()`
  — and thus process exit — stall ~6 s, and any other `open()` blocks behind it (`ps` shows the old
  process in state `E`). That was the "Connect hangs after relaunch" bug.
- **Never send faster than the DMX line can carry the frame** (512 ch ≈ 22.7 ms → 44 Hz; 24 ch ≈
  1.2 ms). Widget intake is ~110 KB/s so the host isn't the limit; excess frames just get overwritten
  in the widget, and the driver silently buffers 100+ KB before `write()` blocks — "write didn't
  block" is not evidence you're keeping up. Use `dmxcli bench` (10 s+) to check pacing changes.
- Label 4 (set params) is **persistent** in the widget across power cycles — always restore.
  Label 10 (get serial) switches the widget's port to input and stops DMX output until the next
  label 6; label 3 (get params) does not.
- The Halo applies a fixed-duration crossfade to intensity/CCT changes in firmware (strobe channel is
  instant). Fades you see are not from this code; there's no fixture setting for it.
