# dmx — toy DMX controller for macOS

A small native Swift/SwiftUI app (plus a CLI) that drives DMX lights through an
**Enttec DMX USB Pro**. Built to poke at an **amaran Halo 300x** on channel 1.

```
./build.sh run              # build + launch the SwiftUI app
./build.sh run --connect --high-speed   # …and connect immediately in high-speed mode
./build.sh app              # release build → dist/DMXControl.app and open it
./build.sh cli info         # query the widget (serial, firmware, break/MAB/refresh)
./build.sh cli halo 50 3200 # Halo @ addr 1: 50% intensity, 3200K, hold 2s
./build.sh cli set 1=255 2=64 --hold 5
./build.sh cli black
./build.sh cli bench --channels 24 --fps 750 --seconds 10   # pacing / backpressure test
```

## Hardware

| What | Detail |
|---|---|
| Interface | Enttec DMX USB Pro, FTDI FT232 (VID `0x0403` PID `0x6001`), USB serial `EN538648` |
| Device node | `/dev/cu.usbserial-EN538648` (macOS built-in `AppleUSBFTDI` driver — no extra driver needed) |
| Widget | firmware 1.44, break 96 µs, MAB 10.7 µs, refresh 40 Hz |
| Light | amaran Halo 300x (bi-color COB, 2700–6500 K), DMX via amaran USB-C → 5-pin DMX adapter, start address 1 |

## How it works

* `Sources/DMXCore/SerialPort.swift` — bare POSIX serial (open/termios/write). The Pro
  ignores baud rate (the FTDI talks to the widget's MCU at a fixed rate); we set 115200 anyway.
* `Sources/DMXCore/EnttecDMXUSBPro.swift` — the widget's message framing:
  `7E <label> <lenLSB> <lenMSB> <data…> E7`. Label 6 = "send DMX packet";
  data = start code `00` + 512 channel bytes (518 bytes on the wire per frame).
  Labels 3/10 read widget parameters / serial number.
* `Sources/DMXCore/AmaranHalo.swift` — Halo 300x channel maps (see below) → DMX bytes.
* `Sources/DMXControl/` — SwiftUI app. `DMXController` holds the 512-channel universe and
  streams it to the widget on a background timer. Two modes:
  * **Normal** — full 512-channel frames at 40 fps (= the widget's own DMX refresh rate;
    a full frame is ~22.7 ms on the wire, so ~44 Hz is the physical ceiling). The widget
    repeats the last frame on its own, so this is plenty for sliders and cues.
  * **High speed** — sets the widget's refresh to 0 ("as fast as possible"), sends only through
    the highest in-use channel (min 24; a channel that drops to 0 keeps the frame long for
    2 s so the fixture actually receives the zero), and paces at the DMX line time of that
    short frame × 1.1. For the Halo's 3 channels that's a 24-channel frame every ~1.3 ms
    → ~750 fps, ~2 ms input-to-light instead of ~50 ms. Widget parameters are restored on
    disconnect/quit.
* `Sources/dmxcli/` — scripting/smoke-test CLI.

The app window has three panes:

1. **amaran Halo 300x** — intensity / CCT / ±green / strobe / CCT+ sliders, DMX profile and
   start-address pickers. Shows the exact bytes it writes.
2. **Channels** — raw sliders for all 512 channels, blackout / full.
3. **DMX Output Debug** — port, widget info, measured fps, byte counter, the last Enttec
   message as a hex dump (short or full 518 bytes, annotated), the currently non-zero
   channels, and a timestamped change log of every frame that differed from the previous one.

## amaran Halo 300x DMX profiles

From *amaran DMX Profile Specification V1.1 (March 2026)* — `docs/amaran-dmx-profile-spec-v1.1.pdf`.
The x-series is bi-color, so only the CCT profiles apply. Pick the profile on the light:
**Menu → DMX Mode → DMX Profile** (and set the address there too).

**Profile 1 · CCT Universal · 3 ch** (default in the app)

| Ch | Function | Values |
|---|---|---|
| 1 | Intensity | 0–255 → 0–100 % |
| 2 | CCT | 0–255 → 2700–6500 K |
| 3 | Strobe | 0–13 off · 14–128 random 1→25+ Hz · 129–255 constant 1→25+ Hz |

**Profile 2 · CCT · 5 ch**

| Ch | Function | Values |
|---|---|---|
| 1 | Intensity | 0–255 → 0–100 % |
| 2 | CCT | 0–255 → 2300–10000 K (CCT+ off) — the Halo clamps to what it can do |
| 3 | ±Green | 0–10 no effect (don't use) · 11–20 full −G · 21–119 −99…−1 % · 120–145 neutral · 146–244 +1…+99 % · 245–255 full +G |
| 4 | Strobe | as above |
| 5 | CCT+ | 0–127 off · 128–255 on |

DMX-loss behaviour is set on the light (hold / blackout / fade / hold 2 min then fade).

## Timing & gotchas (measured, see `dmxcli bench|drain|latency`)

* **Widget intake is fast**: ~100–120 KB/s over USB (≈ 200+ full 512-ch frames/s), so the
  host is never the bottleneck at 40 fps. Frames sent faster than the DMX line can carry are
  simply overwritten inside the widget.
* **DMX line time** = break 96 µs + MAB 10.7 µs + (1 + channels) × 44 µs. 512 ch → 22.7 ms
  (44 Hz), 128 ch → 5.8 ms (173 Hz), 24 ch → 1.2 ms (828 Hz). High-speed mode paces at this
  × 1.1; verified over 10 s with zero backlog (`TIOCOUTQ` stays 0, `write()` never blocks).
* **The baud rate matters even though the Pro ignores it.** The DMX USB Pro's data path
  runs at a fixed speed regardless of the configured baud, but macOS's serial driver
  computes its close()/drain wait as *bytes written ÷ baud*. At 115200 baud a session that
  wrote 60 KB makes `close()` — and therefore process exit — stall ~6 s, and any other
  process trying to open the port blocks behind it ("Connect hangs after relaunch"). We
  open at 3 Mbaud (`IOSSIOSPEED`), which turns that into a few ms. Symptom of getting this
  wrong: `ps` shows the old process in state `E` for seconds after quitting.
* The app closes the port synchronously on quit (⌘Q, window close, SIGINT/SIGTERM) and
  restores the widget's refresh rate if high-speed mode changed it. If a Connect ever does
  hang, wait a few seconds or unplug/replug the widget.

## Requirements

macOS 14+, Swift 5.10+ toolchain (Command Line Tools are enough — no Xcode project needed).
