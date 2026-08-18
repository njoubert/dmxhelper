import Foundation
import DMXCore

// dmxcli — tiny scripting/smoke-test tool for the Enttec DMX USB Pro.
//
//   dmxcli list                                  list serial ports
//   dmxcli info   [--port PATH]                  query widget serial/firmware/params
//   dmxcli set    [--port PATH] [--hold SEC] CH=VAL [CH=VAL ...]
//                                                 send a frame (e.g. 1=255 2=128), hold for SEC seconds (default 2)
//   dmxcli halo   [--port PATH] [--hold SEC] [--addr N] [--profile 1|2] INTENSITY% CCT_K [strobe off|random|constant]
//                                                 e.g. dmxcli halo 50 3200
//   dmxcli black  [--port PATH]                  send all zeros

func die(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("usage: dmxcli list|info|set|halo|black [--port PATH] [--hold SEC] ...")
    exit(2)
}
args.removeFirst()

func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

let portPath = takeOption("--port") ?? SerialPort.availablePorts().first(where: { $0.contains("usbserial") }) ?? ""
let hold = Double(takeOption("--hold") ?? "2") ?? 2

func hex(_ b: [UInt8], max: Int = 24) -> String {
    let shown = b.prefix(max).map { String(format: "%02X", $0) }.joined(separator: " ")
    return b.count > max ? shown + " … (\(b.count) bytes)" : shown
}

func openPort() -> SerialPort {
    guard !portPath.isEmpty else { die("no serial port found; pass --port /dev/cu.usbserial-XXXX") }
    let p = SerialPort(path: portPath)
    do { try p.open() } catch { die(error.localizedDescription) }
    return p
}

func stream(_ universe: [UInt8], seconds: Double, fps: Double = 30) {
    let p = openPort()
    let pkt = EnttecPro.dmxPacket(universe: universe)
    let nonzero = universe.enumerated().filter { $0.element != 0 }.map { "ch\($0.offset + 1)=\($0.element)" }
    print("port:    \(portPath)")
    print("frame:   \(nonzero.isEmpty ? "(all zero)" : nonzero.joined(separator: " "))")
    print("packet:  \(hex(pkt))")
    print("holding \(seconds)s at \(Int(fps)) fps (widget keeps repeating the last frame afterwards)…")
    let frames = Int(seconds * fps)
    for _ in 0..<max(1, frames) {
        do { try p.write(pkt) } catch { die(error.localizedDescription) }
        usleep(useconds_t(1_000_000 / fps))
    }
    p.close()
}

switch cmd {
case "list":
    for p in SerialPort.availablePorts() { print(p) }

case "info":
    let p = openPort()
    try? p.write(EnttecPro.getSerialRequest())
    let s = p.read(max: 64, timeout: 0.5)
    try? p.write(EnttecPro.getParametersRequest())
    let q = p.read(max: 64, timeout: 0.5)
    print("port:     \(portPath)")
    if let m = EnttecPro.parseMessage(s), let sn = EnttecPro.parseSerial(m.data) { print("serial:   \(sn)") } else { print("serial:   (no reply) raw=\(hex(s))") }
    if let m = EnttecPro.parseMessage(q), let prm = EnttecPro.parseParameters(m.data) {
        print("firmware: \(prm.firmwareVersion >> 8).\(prm.firmwareVersion & 0xFF)")
        print(String(format: "break:    %d (%.1f µs)", prm.breakTime, Double(prm.breakTime) * 10.67))
        print(String(format: "MAB:      %d (%.1f µs)", prm.mabTime, Double(prm.mabTime) * 10.67))
        print("refresh:  \(prm.refreshRate) Hz")
    } else { print("params:   (no reply) raw=\(hex(q))") }
    p.close()

case "set":
    var universe = [UInt8](repeating: 0, count: 512)
    for a in args {
        let parts = a.split(separator: "=")
        guard parts.count == 2, let ch = Int(parts[0]), (1...512).contains(ch), let v = Int(parts[1]), (0...255).contains(v)
        else { die("bad assignment '\(a)', expected CH=VAL with CH 1–512, VAL 0–255") }
        universe[ch - 1] = UInt8(v)
    }
    stream(universe, seconds: hold)

case "halo":
    let addr = Int(takeOption("--addr") ?? "1") ?? 1
    let profile: HaloProfile = (takeOption("--profile") ?? "1") == "2" ? .cct5ch : .cctUniversal3ch
    guard args.count >= 2, let intensity = Double(args[0]), let cct = Double(args[1]) else { die("usage: dmxcli halo INTENSITY% CCT_K [off|random|constant]") }
    var st = HaloState()
    st.intensity = intensity; st.cct = cct
    if args.count >= 3, let m = StrobeMode(rawValue: args[2].capitalized) { st.strobe = m; st.strobeRate = 0.5 }
    var universe = [UInt8](repeating: 0, count: 512)
    let bytes = st.encode(profile: profile)
    for (i, b) in bytes.enumerated() where addr + i <= 512 { universe[addr - 1 + i] = b }
    print("halo:    \(profile.rawValue) @ address \(addr) → \(bytes)")
    stream(universe, seconds: hold)

case "black":
    stream([UInt8](repeating: 0, count: 512), seconds: 1)

default:
    die("unknown command \(cmd)")
}
