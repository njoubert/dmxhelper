import Foundation
import DMXCore

func receiveSelfTest() {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "ok  " : "FAIL") \(name)"); if !ok { failures += 1 }
    }

    // A label-5 message carrying slots 1…64 = 1…64.
    var payload: [UInt8] = [0x00, 0x00]                       // status, start code
    payload += (1...64).map { UInt8($0) }
    let msg = EnttecPro.frame(.receivedDMXPacket, payload)

    var s = EnttecPro.MessageStream()
    s.append(msg)
    let m = s.next()
    check("whole message parses", m?.label == 5 && m?.data.count == 66)
    let rx = m.flatMap { EnttecPro.parseReceivedDMX($0.data) }
    check("slots decoded, start code stripped", rx?.slots.count == 64 && rx?.slots.first == 1 && rx?.slots.last == 64)
    check("start code 0 = dimmer data", rx?.isDimmerData == true && rx?.overflow == false && rx?.overrun == false)
    check("stream drained", s.next() == nil && s.pending == 0)

    // Split across reads, one byte at a time — the real port hands over arbitrary chunks.
    var s2 = EnttecPro.MessageStream()
    var got = 0
    for b in msg { s2.append([b]); while s2.next() != nil { got += 1 } }
    check("reassembles from single-byte reads", got == 1 && s2.resyncs == 0)

    // Two messages back to back, with junk in front and between.
    var s3 = EnttecPro.MessageStream()
    s3.append([0xAA, 0xBB] + msg + [0x12] + msg)
    var count = 0
    while s3.next() != nil { count += 1 }
    check("resyncs past junk, finds both", count == 2 && s3.resyncs >= 2)

    // Status bits.
    let bad = EnttecPro.parseReceivedDMX([0x03, 0x00, 9, 9])
    check("status bits", bad?.overflow == true && bad?.overrun == true)

    // Reply lookup skips received-DMX chatter (what happens after the widget starts listening).
    let params = EnttecPro.frame(.getWidgetParameters, [0x2C, 0x01, 9, 1, 40])
    let d = EnttecPro.message(.getWidgetParameters, in: msg + params)
    check("finds a reply behind DMX chatter", EnttecPro.parseParameters(d ?? [])?.refreshRate == 40)
    check("absent label returns nil", EnttecPro.message(.getWidgetSerial, in: msg) == nil)

    // Malformed: bad EOM must not swallow the following good message.
    var broken = msg; broken[broken.count - 1] = 0x00
    var s4 = EnttecPro.MessageStream()
    s4.append(broken + msg)
    check("bad terminator recovers", s4.next() != nil)

    // Change of state: block 0 covers start code + slots 1…39; block 1 slots 40…79.
    var slots = [UInt8](repeating: 0, count: 512)
    // block 0, flag bits 1 and 3 (= slots 1 and 3), packed values 111, 222
    var cos: [UInt8] = [0, 0b0000_1010, 0, 0, 0, 0, 111, 222]
    var changed = EnttecPro.applyChangeOfState(cos, to: &slots)
    check("delta lands on slots 1 and 3", changed == [1, 3] && slots[0] == 111 && slots[2] == 222)
    // block 1, bit 0 = buffer byte 40 = slot 40
    cos = [1, 0b0000_0001, 0, 0, 0, 0, 77]
    changed = EnttecPro.applyChangeOfState(cos, to: &slots)
    check("second block offsets by 40", changed == [40] && slots[39] == 77)
    // Bit 0 of block 0 is the start code: it consumes its value byte but changes no slot.
    changed = EnttecPro.applyChangeOfState([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 5], to: &slots)
    check("start-code bit changes no slot", changed.isEmpty)
    // Truncated payload must stop at the data it has, not read past the end.
    changed = EnttecPro.applyChangeOfState([1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 5], to: &slots)
    check("truncated delta stops at the data", changed == [40] && slots[39] == 5)

    print(failures == 0 ? "\nall receive-path checks passed" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
