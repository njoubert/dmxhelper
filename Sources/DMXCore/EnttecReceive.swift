import Foundation

// Receiving DMX — the Pro's DMX IN port.
//
// The widget says nothing about its input until it gets a "Receive DMX on Change of State"
// request (label 8). After that it pushes what it sees on DMX IN to the host: either every
// frame (label 5) or only the slots that changed (label 9). It stops as soon as it gets a
// Send DMX Packet (label 6) — input and output are mutually exclusive on the DMX USB Pro,
// so monitoring means giving up transmitting.
//
// Consequence for everything else in this codebase: once the widget is in receive mode it is
// chattering label 5 messages, so a reply you asked for (params, serial) is no longer the
// first message in the buffer. Parse replies with `EnttecPro.message(_:in:)`, never by
// assuming byte 0 is the start of the message you wanted.
extension EnttecPro {

    public enum ReceiveMode: Sendable {
        /// Widget sends one label-5 message per DMX frame it receives (~44 Hz for a full universe).
        case always
        /// Widget sends label-9 delta blocks only when slots change. Much less traffic, but
        /// you only see a slot after it moves.
        case onChange
    }

    /// Label 8 — put the widget into receive mode.
    public static func receiveDMXRequest(_ mode: ReceiveMode = .always) -> [UInt8] {
        frame(.receiveDMXOnChange, [mode == .onChange ? 1 : 0])
    }

    /// A DMX frame the widget saw on its input (label 5).
    public struct ReceivedDMX: Sendable, Equatable {
        public var status: UInt8
        public var startCode: UInt8
        /// Slot 1…n, start code stripped. A DMX source may send fewer than 512 slots.
        public var slots: [UInt8]

        /// Widget's receive FIFO overflowed — we are not draining the port fast enough.
        public var overflow: Bool { status & 0x01 != 0 }
        /// Line trouble: overrun / framing error on the incoming DMX.
        public var overrun: Bool { status & 0x02 != 0 }
        /// Start code 0 is ordinary dimmer data; anything else is RDM/text/manufacturer traffic.
        public var isDimmerData: Bool { startCode == 0 }

        public init(status: UInt8, startCode: UInt8, slots: [UInt8]) {
            self.status = status; self.startCode = startCode; self.slots = slots
        }
    }

    public static func parseReceivedDMX(_ data: [UInt8]) -> ReceivedDMX? {
        guard data.count >= 2 else { return nil }
        return ReceivedDMX(status: data[0], startCode: data[1], slots: Array(data.dropFirst(2)))
    }

    /// Apply a label-9 change-of-state block to a 512-slot universe; returns the 1-based slot
    /// numbers that changed.
    ///
    /// Layout per the Enttec API doc: byte 0 is a *block* index — the block covers 40 buffer
    /// bytes starting at `block × 40`, where buffer byte 0 is the start code and byte 1 is slot 1.
    /// Bytes 1…5 are 40 bits (LSB first) flagging which of those 40 bytes are present, and
    /// bytes 6… are the flagged values packed consecutively.
    /// UNTESTED: generating change-of-state traffic needs a second DMX source. If deltas ever
    /// land in the wrong slots, the packing is the thing to doubt (positional 40-byte array
    /// instead of packed is the other reading of the doc).
    public static func applyChangeOfState(_ data: [UInt8], to slots: inout [UInt8]) -> [Int] {
        guard data.count >= 6 else { return [] }
        let base = Int(data[0]) * 40
        var changed: [Int] = []
        var next = 6
        for bit in 0..<40 {
            guard (data[1 + bit / 8] >> UInt8(bit % 8)) & 1 == 1 else { continue }
            guard next < data.count else { break }
            let value = data[next]; next += 1
            let slot = base + bit                 // buffer offset: 0 = start code, 1 = slot 1
            guard slot >= 1, slot <= slots.count else { continue }
            slots[slot - 1] = value
            changed.append(slot)
        }
        return changed
    }

    /// Incremental framer for the widget→host direction. Append bytes as they arrive off the
    /// port, pop whole messages. Anything that isn't a well-formed `7E … E7` is dropped a byte
    /// at a time until it resyncs (`resyncs` counts how often that happened).
    public struct MessageStream: Sendable {
        private var buf: [UInt8] = []
        public private(set) var resyncs = 0
        public var pending: Int { buf.count }

        public init() {}

        public mutating func append(_ bytes: [UInt8]) { buf.append(contentsOf: bytes) }

        public mutating func next() -> (label: UInt8, data: [UInt8])? {
            while true {
                guard let som = buf.firstIndex(of: EnttecPro.som) else {
                    if !buf.isEmpty { resyncs += 1; buf.removeAll() }
                    return nil
                }
                if som > 0 { resyncs += 1; buf.removeFirst(som) }
                guard buf.count >= 5 else { return nil }              // header + EOM at minimum
                let len = Int(buf[2]) | (Int(buf[3]) << 8)
                guard len <= 600 else { resyncs += 1; buf.removeFirst(); continue }
                guard buf.count >= len + 5 else { return nil }        // incomplete: wait for more
                guard buf[len + 4] == EnttecPro.eom else { resyncs += 1; buf.removeFirst(); continue }
                let msg = (label: buf[1], data: Array(buf[4..<(len + 4)]))
                buf.removeFirst(len + 5)
                return msg
            }
        }
    }

    /// Find the payload of the first message with `label` in a buffer, skipping anything else
    /// (received-DMX chatter, a stale reply) that arrived first.
    public static func message(_ label: Label, in bytes: [UInt8]) -> [UInt8]? {
        var stream = MessageStream()
        stream.append(bytes)
        while let m = stream.next() {
            if m.label == label.rawValue { return m.data }
        }
        return nil
    }
}
