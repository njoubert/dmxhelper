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

    public struct WidgetParameters: Sendable, Equatable {
        public var firmwareVersion: UInt16
        public var breakTime: UInt8      // units of 10.67 µs
        public var mabTime: UInt8        // units of 10.67 µs
        public var refreshRate: UInt8    // packets/sec, 0 = as fast as possible

        public init(firmwareVersion: UInt16, breakTime: UInt8, mabTime: UInt8, refreshRate: UInt8) {
            self.firmwareVersion = firmwareVersion; self.breakTime = breakTime
            self.mabTime = mabTime; self.refreshRate = refreshRate
        }
        /// The widget's factory-ish defaults (what ours reported: break 96 µs, MAB 10.7 µs, 40 Hz).
        public static let defaults = WidgetParameters(firmwareVersion: 0, breakTime: 9, mabTime: 1, refreshRate: 40)
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

    /// The widget will not output fewer than this many channels per frame.
    public static let minChannels = 24

    /// Build a "Send DMX Packet" message. `channels` limits how many slots are sent
    /// (clamped to 24…512); a shorter frame is faster on the DMX line.
    /// The widget requires the DMX start code (0x00 for standard dimmer data) as the first byte.
    public static func dmxPacket(universe: [UInt8], channels: Int = 512) -> [UInt8] {
        let n = min(max(channels, minChannels), 512)
        var data = [UInt8](repeating: 0, count: n + 1)
        data[0] = 0x00 // start code
        let avail = min(universe.count, n)
        if avail > 0 { data.replaceSubrange(1..<(1 + avail), with: universe[0..<avail]) }
        return frame(.sendDMXPacket, data)
    }

    /// Set Widget Parameters (label 4). Values persist in the widget until changed again.
    /// - breakTime: 9…127 (×10.67 µs), mabTime: 1…127 (×10.67 µs),
    /// - refreshRate: 1…40 packets/s, or 0 = as fast as the frame length allows.
    public static func setParametersRequest(breakTime: UInt8, mabTime: UInt8, refreshRate: UInt8) -> [UInt8] {
        frame(.setWidgetParameters, [0, 0, max(9, min(127, breakTime)), max(1, min(127, mabTime)), min(40, refreshRate)])
    }

    // MARK: Timing model

    /// Time one DMX frame occupies on the DMX512 line: break + MAB + (1 + channels) slots at 44 µs.
    public static func dmxLineTime(channels: Int, breakTime: UInt8 = 9, mabTime: UInt8 = 1) -> TimeInterval {
        let brk = Double(breakTime) * 10.67e-6, mab = Double(mabTime) * 10.67e-6
        return brk + mab + Double(1 + channels) * 44e-6
    }

    /// Bytes on the USB/serial side for one send-DMX message (5 header/trailer + start code + channels).
    public static func packetBytes(channels: Int) -> Int { channels + 6 }

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
