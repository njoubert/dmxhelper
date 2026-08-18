import Foundation

/// Enttec DMX USB Pro widget protocol.
///
/// Framing: 0x7E, label, lengthLSB, lengthMSB, data..., 0xE7
/// See "DMX USB PRO API" (Enttec).
public enum EnttecPro {
    public static let som: UInt8 = 0x7E
    public static let eom: UInt8 = 0xE7

    public enum Label: UInt8 {
        case reprogramFirmware      = 1
        case flashPage              = 2
        case getWidgetParameters    = 3
        case setWidgetParameters    = 4
        case receivedDMXPacket      = 5
        case sendDMXPacket          = 6   // Output Only Send DMX Packet Request
        case sendRDMPacket          = 7
        case receiveDMXOnChange     = 8
        case receivedDMXChangeOfState = 9
        case getWidgetSerial        = 10
        case sendRDMDiscovery       = 11
    }

    public struct WidgetParameters {
        public var firmwareVersion: UInt16
        public var breakTime: UInt8      // units of 10.67 µs
        public var mabTime: UInt8        // units of 10.67 µs
        public var refreshRate: UInt8    // packets/sec, 0 = as fast as possible
    }

    /// Wrap a payload in the widget message framing.
    public static func frame(_ label: Label, _ data: [UInt8]) -> [UInt8] {
        precondition(data.count <= 600, "Enttec payload too large")
        var msg = [UInt8]()
        msg.reserveCapacity(data.count + 5)
        msg.append(som)
        msg.append(label.rawValue)
        msg.append(UInt8(data.count & 0xFF))
        msg.append(UInt8((data.count >> 8) & 0xFF))
        msg.append(contentsOf: data)
        msg.append(eom)
        return msg
    }

    /// Build a "Send DMX Packet" message for a full 512-channel universe.
    /// The widget requires the DMX start code (0x00 for standard dimmer data) as the first byte.
    public static func dmxPacket(universe: [UInt8]) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 513)
        data[0] = 0x00 // start code
        let n = min(universe.count, 512)
        if n > 0 { data.replaceSubrange(1..<(1 + n), with: universe[0..<n]) }
        return frame(.sendDMXPacket, data)
    }

    public static func getParametersRequest() -> [UInt8] {
        // user configuration size (LSB, MSB) = 0
        frame(.getWidgetParameters, [0, 0])
    }

    public static func getSerialRequest() -> [UInt8] {
        frame(.getWidgetSerial, [])
    }

    /// Parse the first complete message out of a byte buffer. Returns (label, data) or nil.
    public static func parseMessage(_ bytes: [UInt8]) -> (label: UInt8, data: [UInt8])? {
        guard let start = bytes.firstIndex(of: som), bytes.count >= start + 5 else { return nil }
        let label = bytes[start + 1]
        let len = Int(bytes[start + 2]) | (Int(bytes[start + 3]) << 8)
        let dataStart = start + 4
        let dataEnd = dataStart + len
        guard bytes.count > dataEnd, bytes[dataEnd] == eom else { return nil }
        return (label, Array(bytes[dataStart..<dataEnd]))
    }

    public static func parseParameters(_ data: [UInt8]) -> WidgetParameters? {
        guard data.count >= 5 else { return nil }
        return WidgetParameters(
            firmwareVersion: UInt16(data[0]) | (UInt16(data[1]) << 8),
            breakTime: data[2],
            mabTime: data[3],
            refreshRate: data[4]
        )
    }

    /// Serial number is 4 bytes BCD, LSB first.
    public static func parseSerial(_ data: [UInt8]) -> String? {
        guard data.count >= 4 else { return nil }
        return data[0..<4].reversed().map { String(format: "%02X", $0) }.joined()
    }
}
