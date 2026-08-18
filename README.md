# dmx — toy DMX controller for macOS

A small native Swift/SwiftUI app (plus a CLI) that drives DMX lights through an
**Enttec DMX USB Pro**. Built to poke at an **amaran Halo 300x** on channel 1.

```
./build.sh run              # build + launch the SwiftUI app
./build.sh app              # release build → dist/DMXControl.app and open it
./build.sh cli info         # query the widget (serial, firmware, break/MAB/refresh)
./build.sh cli halo 50 3200 # Halo @ addr 1: 50% intensity, 3200K, hold 2s
./build.sh cli set 1=255 2=64 --hold 5
./build.sh cli black
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
  streams it to the widget on a background timer (30 fps default; the widget also
  repeats the last frame on its own).
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

## Requirements

macOS 14+, Swift 5.10+ toolchain (Command Line Tools are enough — no Xcode project needed).
