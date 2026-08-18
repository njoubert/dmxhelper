import Foundation
import Darwin
import DMXCore

// Live view of the widget's DMX IN port. See EnttecReceive.swift for the protocol side;
// the important part is that receiving is a *mode*: the widget stops transmitting while we
// watch, and goes back to output on the next label 6.

nonisolated(unsafe) var monitorStop: sig_atomic_t = 0

/// print() buffers when stdout is a pipe while raw fd writes don't, which reorders the display
/// against the header. Everything goes through here instead.
private func emit(_ s: String) { print(s, terminator: ""); fflush(stdout) }

/// 256-colour heat cell for a DMX level: near-black at 0, ramping red → amber → white at 255.
private func heat(_ v: UInt8) -> (bg: Int, fg: Int) {
    guard v > 0 else { return (233, 239) }
    let t = Double(v) / 255
    func c(_ x: Double) -> Int { Swift.max(0, Swift.min(5, Int((x * 5).rounded()))) }
    let r = Swift.max(1, c(t * 1.6))
    let g = c((t - 0.25) * 1.6)
    let b = c((t - 0.60) * 2.5)
    let lum = 0.3 * Double(r) + 0.6 * Double(g) + 0.1 * Double(b)
    return (16 + 36 * r + 6 * g + b, lum >= 2.5 ? 16 : 231)
}

private func terminalColumns() -> Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 20 { return Int(w.ws_col) }
    return 100
}

struct MonitorOptions {
    var mode: EnttecPro.ReceiveMode = .always
    var seconds: Double? = nil
    var raw = false
    var demo = false
    var maxSlot = 512
}

/// Synthetic label-5 messages: a chase running under a slow swell. Goes through the very same
/// framing and parsing as the widget's own bytes, so `--demo` exercises everything but the wire.
private func demoBytes(_ t: TimeInterval) -> [UInt8] {
    var slots = [UInt8](repeating: 0, count: 48)
    for i in 0..<48 {
        let phase = t * 1.6 - Double(i) * 0.13
        let chase = Swift.max(0, sin(phase))
        let swell = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 0.55))
        slots[i] = UInt8(Swift.min(255, (pow(chase, 3) * 255 * swell).rounded()))
    }
    return EnttecPro.frame(.receivedDMXPacket, [0x00, 0x00] + slots)
}

/// `port` is nil in demo mode: frames are generated locally instead of read off the widget.
func runMonitor(port: SerialPort?, portPath: String, options: MonitorOptions) {
    let reset = "\u{1B}[0m", dim = "\u{1B}[2m"

    var widget = "synthetic frames"
    if let port {
        // Prove the port is a Pro before we change its mode, and read params past any chatter.
        try? port.write(EnttecPro.getParametersRequest())
        let reply = port.read(max: 128, timeout: 0.5)
        widget = "(no reply to get-params — is this an Enttec Pro?)"
        if let d = EnttecPro.message(.getWidgetParameters, in: reply), let p = EnttecPro.parseParameters(d) {
            widget = "firmware \(p.firmwareVersion >> 8).\(p.firmwareVersion & 0xFF), refresh \(p.refreshRate) Hz"
        }
        do { try port.write(EnttecPro.receiveDMXRequest(options.mode)) }
        catch { die(error.localizedDescription) }
    }

    let modeName = options.mode == .always ? "send-always (label 5)" : "on-change (label 9)"
    print("DMX IN   \(portPath)   \(widget)")
    print("mode:    \(modeName) — the widget stops transmitting while it listens")
    print("stop with ^C\n")

    monitorStop = 0
    signal(SIGINT) { _ in monitorStop = 1 }
    signal(SIGTERM) { _ in monitorStop = 1 }

    var stream = EnttecPro.MessageStream()
    var slots = [UInt8](repeating: 0, count: 512)
    var lastChange = [Date](repeating: .distantPast, count: 512)
    var frames = 0, deltas = 0, errors = 0, overruns = 0, otherMessages = 0
    var slotsSeen = 0, hwm = 0
    var startCodes = Set<UInt8>()
    var recentFrames: [Date] = []
    var lastFrameAt: Date? = nil
    var lastDraw = Date.distantPast
    let started = Date()
    var drewGrid = false

    func note(_ received: EnttecPro.ReceivedDMX) {
        frames += 1
        startCodes.insert(received.startCode)
        if received.overflow { errors += 1 }
        if received.overrun { overruns += 1 }
        slotsSeen = max(slotsSeen, received.slots.count)
        let now = Date()
        for (i, v) in received.slots.enumerated() where i < 512 {
            if slots[i] != v { slots[i] = v; lastChange[i] = now }
            if v != 0 { hwm = max(hwm, i + 1) }
        }
        lastFrameAt = now
        recentFrames.append(now)
    }

    while monitorStop == 0 {
        if let s = options.seconds, Date().timeIntervalSince(started) >= s { break }

        if let port {
            stream.append(port.readAvailable())        // blocks ≤100 ms when the line is quiet
        } else {
            stream.append(demoBytes(Date().timeIntervalSince(started)))
            usleep(25_000)                             // ~40 fps, like a real DMX source
        }
        while let msg = stream.next() {
            switch msg.label {
            case EnttecPro.Label.receivedDMXPacket.rawValue:
                guard let rx = EnttecPro.parseReceivedDMX(msg.data) else { break }
                if options.raw {
                    print(String(format: "%7.3f  label 5  len %4d  status %02X  start %02X  %@",
                                 Date().timeIntervalSince(started), msg.data.count, rx.status, rx.startCode,
                                 hex(rx.slots, max: 16)))
                }
                note(rx)
            case EnttecPro.Label.receivedDMXChangeOfState.rawValue:
                let changed = EnttecPro.applyChangeOfState(msg.data, to: &slots)
                let now = Date()
                for slot in changed { lastChange[slot - 1] = now; if slots[slot - 1] != 0 { hwm = max(hwm, slot) } }
                deltas += 1
                lastFrameAt = now
                recentFrames.append(now)
                if options.raw {
                    print(String(format: "%7.3f  label 9  len %4d  changed %@",
                                 Date().timeIntervalSince(started), msg.data.count,
                                 changed.prefix(12).map(String.init).joined(separator: ",")))
                }
            default:
                otherMessages += 1
                if options.raw {
                    print(String(format: "%7.3f  label %d  len %4d  %@",
                                 Date().timeIntervalSince(started), msg.label, msg.data.count, hex(msg.data, max: 16)))
                }
            }
        }

        // Redraw at ~12 Hz; the widget can deliver 44 frames/s and the terminal shouldn't try.
        let now = Date()
        guard !options.raw, now.timeIntervalSince(lastDraw) > 0.08 else { continue }
        lastDraw = now
        recentFrames.removeAll { now.timeIntervalSince($0) > 1 }

        let live = lastFrameAt.map { now.timeIntervalSince($0) < 1.0 } ?? false
        var out = "\u{1B}[H\u{1B}[J"                    // home, clear below
        out += "DMX IN   \(portPath)   \(modeName)\(reset)\n"

        if !live {
            let waited = String(format: "%.0f", now.timeIntervalSince(lastFrameAt ?? started))
            out += lastFrameAt == nil
                ? "\n  \u{1B}[33mwaiting for DMX on the widget's IN port… (\(waited)s, nothing received yet)\(reset)\n"
                : "\n  \u{1B}[33msignal lost \(waited)s ago — last frame still shown below\(reset)\n"
            if lastFrameAt == nil {
                out += "\(dim)  Nothing is driving the input. Feed it from a console, a node, or another\n"
                out += "  widget's DMX OUT — this one can't send while it listens.\(reset)\n"
                out += String(format: "\n\(dim)  frames 0   other messages %d   resyncs %d   elapsed %.0fs\(reset)\n",
                              otherMessages, stream.resyncs, now.timeIntervalSince(started))
                emit(out)
                drewGrid = false
                continue
            }
        }

        let fps = Double(recentFrames.count)
        let active = slots.prefix(max(hwm, 1)).filter { $0 != 0 }.count
        let codes = startCodes.map { String(format: "0x%02X", $0) }.sorted().joined(separator: ",")
        out += String(format: "\(dim)frames\(reset) %-7d \(dim)fps\(reset) %-5.1f \(dim)start\(reset) %-6@ \(dim)slots\(reset) %-4d \(dim)lit\(reset) %-4d \(dim)err\(reset) %d/%d \(dim)elapsed\(reset) %.0fs\n",
                      frames + deltas, fps, codes.isEmpty ? "—" : codes,
                      slotsSeen, active, errors, overruns, now.timeIntervalSince(started))

        // Grid: as many 3-char cells per row as the terminal fits, rows trimmed to the
        // highest slot ever lit (a channel that drops to 0 keeps its row).
        let perRow = [32, 24, 16, 12, 8].first { $0 * 4 + 6 <= terminalColumns() } ?? 8
        let shown = min(options.maxSlot, max(perRow * 2, ((max(hwm, 1) + perRow - 1) / perRow) * perRow))
        out += "      " + (0..<perRow).map { String(format: "\(dim)%4d\(reset)", $0) }.joined() + "\n"
        for row in stride(from: 0, to: shown, by: perRow) {
            out += String(format: "\(dim)%5d\(reset) ", row + 1)
            for i in row..<min(row + perRow, shown) {
                let v = slots[i]
                let (bg, fg) = heat(v)
                let fresh = now.timeIntervalSince(lastChange[i]) < 0.4
                out += "\u{1B}[48;5;\(bg)m\u{1B}[38;5;\(fg)m\(fresh ? "\u{1B}[1m" : "")"
                out += v == 0 ? "   ·" : String(format: "%4d", Int(v))
                out += reset
            }
            out += "\n"
        }
        if shown < min(options.maxSlot, 512) {
            out += "\(dim)     … slots \(shown + 1)–\(min(options.maxSlot, 512)) never lit\(reset)\n"
        }
        emit(out)
        drewGrid = true
    }

    if drewGrid { print("") }
    let el = Date().timeIntervalSince(started)
    print(String(format: "\n%d frames + %d change-blocks in %.1fs (%.1f/s), %d other messages, %d resyncs, %d overflow / %d overrun",
                 frames, deltas, el, Double(frames + deltas) / el, otherMessages, stream.resyncs, errors, overruns))
    if frames + deltas == 0 { print("nothing arrived on DMX IN.") }
    if port != nil {
        print("widget stays in receive mode until something sends a DMX frame (any dmxcli set/halo, or the app connecting).")
    }
    port?.close()
}


/// Loopback self-test: latch a recognisable frame on DMX OUT, then switch the widget to
/// listening and see whether it comes back on DMX IN.
///
/// Needs a 5-pin cable from the widget's OUT to its IN. It also settles the question the
/// Enttec API only implies: the Pro treats receiving as a *mode*, so if it stops driving the
/// line the moment it starts listening, nothing can come back and this reports silence.
func runLoopback(port: SerialPort, portPath: String, seconds: Double, channels: Int) {
    let n = Swift.max(EnttecPro.minChannels, Swift.min(512, channels))
    var universe = [UInt8](repeating: 0, count: 512)
    for i in 0..<n { universe[i] = UInt8(truncatingIfNeeded: i + 1) }   // slot k holds k
    let pkt = EnttecPro.dmxPacket(universe: universe, channels: n)

    print("port:     \(portPath)")
    print("pattern:  slot k = k, over \(n) slots — \(hex(Array(universe[0..<8]), max: 8)) …")
    print("cable:    this only sees anything with DMX OUT patched back into DMX IN\n")

    do {
        for _ in 0..<10 { try port.write(pkt) }        // let the widget latch and start repeating it
        usleep(300_000)
        try port.write(EnttecPro.receiveDMXRequest(.always))
    } catch { die(error.localizedDescription) }

    var stream = EnttecPro.MessageStream()
    var frames = 0, matched = 0, mismatched = 0
    var firstFrame: EnttecPro.ReceivedDMX? = nil
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        stream.append(port.readAvailable())
        while let msg = stream.next() {
            guard msg.label == EnttecPro.Label.receivedDMXPacket.rawValue,
                  let rx = EnttecPro.parseReceivedDMX(msg.data) else { continue }
            frames += 1
            if firstFrame == nil { firstFrame = rx }
            let good = rx.slots.enumerated().allSatisfy { $0.offset >= n || $0.element == universe[$0.offset] }
            if good && rx.slots.count >= n { matched += 1 } else { mismatched += 1 }
        }
    }

    let el = Date().timeIntervalSince(started)
    print(String(format: "received %d frames in %.1fs (%.1f/s): %d matching the pattern, %d not",
                 frames, el, Double(frames) / el, matched, mismatched))
    if let f = firstFrame {
        print("first frame: start code 0x\(String(format: "%02X", f.startCode)), \(f.slots.count) slots, \(hex(Array(f.slots.prefix(8)), max: 8)) …")
    }
    if matched > 0 {
        print("\nLOOPBACK OK — the Pro transmits and receives at the same time.")
    } else if frames > 0 {
        print("\nframes arrived but none matched: something else is driving that line.")
    } else {
        print("\nnothing came back. Either OUT isn't patched to IN, or the widget stopped")
        print("driving the line when it started listening (receive is a mode — the API says")
        print("output resumes on the next label 6). A second DMX source settles which.")
    }
    try? port.write(EnttecPro.dmxPacket(universe: [UInt8](repeating: 0, count: 512)))  // back to output, blacked out
    usleep(50_000)
    port.close()
    print("widget put back in output mode with a blackout frame.")
}


/// Loopback, alternating: transmit the pattern, then flip to listening, over and over.
///
/// If the Pro really is mode-exclusive, a plain loopback can never see anything — it stops
/// driving the line at the moment it starts listening. This asks a narrower question: with the
/// line driven right up to the switch, does *any* frame land in the receiver? Frames coming back
/// prove the receiver and the cable both work and only simultaneity is missing; silence over many
/// cycles says the widget can't hear its own output at all.
func runLoopbackAlternating(port: SerialPort, portPath: String, seconds: Double, channels: Int) {
    let n = Swift.max(EnttecPro.minChannels, Swift.min(512, channels))
    var universe = [UInt8](repeating: 0, count: 512)
    for i in 0..<n { universe[i] = UInt8(truncatingIfNeeded: i + 1) }
    let pkt = EnttecPro.dmxPacket(universe: universe, channels: n)

    print("port:     \(portPath)")
    print("cycle:    transmit 40 ms → listen 60 ms, repeating for \(seconds)s\n")

    var stream = EnttecPro.MessageStream()
    var frames = 0, matched = 0, cycles = 0, otherBytes = 0
    var firstFrame: EnttecPro.ReceivedDMX? = nil
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        cycles += 1
        do {
            try port.write(pkt)                                  // back to output mode, drive the line
            usleep(40_000)                                       // ~2 frames at the widget's 40 Hz
            try port.write(EnttecPro.receiveDMXRequest(.always))  // now listen
        } catch { die(error.localizedDescription) }

        let window = Date().addingTimeInterval(0.06)
        while Date() < window {
            let bytes = port.readAvailable(max: 2048)
            if bytes.isEmpty { continue }
            otherBytes += bytes.count
            stream.append(bytes)
            while let msg = stream.next() {
                guard msg.label == EnttecPro.Label.receivedDMXPacket.rawValue,
                      let rx = EnttecPro.parseReceivedDMX(msg.data) else { continue }
                frames += 1
                if firstFrame == nil { firstFrame = rx }
                if rx.slots.count >= n, rx.slots.enumerated().allSatisfy({ $0.offset >= n || $0.element == universe[$0.offset] }) {
                    matched += 1
                }
            }
        }
    }

    print("\(cycles) transmit/listen cycles, \(otherBytes) bytes back from the widget, \(frames) DMX frames (\(matched) matching the pattern)")
    if let f = firstFrame {
        print("first frame: start code 0x\(String(format: "%02X", f.startCode)), \(f.slots.count) slots, \(hex(Array(f.slots.prefix(8)), max: 8)) …")
    }
    print(matched > 0
          ? "\nthe receiver hears the widget's own output — only simultaneity is missing."
          : "\nnothing over \(cycles) cycles: the widget does not hear its own output.")
    try? port.write(EnttecPro.dmxPacket(universe: [UInt8](repeating: 0, count: 512)))
    usleep(50_000)
    port.close()
}
