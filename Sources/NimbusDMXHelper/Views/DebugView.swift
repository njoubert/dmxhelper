// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import DMXCore

/// Shows exactly what is going out over the serial port to the Enttec widget.
struct DebugView: View {
    @EnvironmentObject var dmx: DMXController
    @State private var showFullPacket = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DMX Output Debug").font(.headline)
                Spacer()
                Toggle("Full 518-byte hex", isOn: $showFullPacket).toggleStyle(.checkbox)
                Button("Clear log") { dmx.clearChangeLog() }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    Text(dmx.isConnected ? dmx.selectedPort : "— (not connected)")
                }
                GridRow {
                    Text("Widget").foregroundStyle(.secondary)
                    Text(dmx.widgetInfo.isEmpty ? "—" : dmx.widgetInfo)
                }
                GridRow {
                    Text("Mode").foregroundStyle(.secondary)
                    Text(modeDescription)
                }
                GridRow {
                    Text("Rate").foregroundStyle(.secondary)
                    Text(dmx.isConnected
                         ? String(format: "%.0f fps measured (target %.0f) · %d frames · %@",
                                  dmx.debug.measuredFPS, 1 / max(dmx.debug.targetInterval, 1e-6), dmx.framesSent, byteString(dmx.debug.bytesSent))
                         : "—")
                }
                GridRow {
                    Text("Frame").foregroundStyle(.secondary)
                    Text(frameDescription)
                }
                GridRow {
                    Text("Last sent").foregroundStyle(.secondary)
                    Text(dmx.debug.lastSentAt.map { Self.fmt.string(from: $0) } ?? "—")
                }
                GridRow {
                    Text("Errors").foregroundStyle(.secondary)
                    Text("\(dmx.debug.writeErrors) write errors")
                }
            }
            .font(.system(.caption, design: .monospaced))

            Divider()

            Text("Active channels (non-zero):").font(.caption).foregroundStyle(.secondary)
            Text(DMXController.describeActive(dmx.channels))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)

            Text("Enttec message on the wire (7E label lenLSB lenMSB | startcode ch1 ch2 … | E7):")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.vertical) {
                Text(packetHex)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: showFullPacket ? 220 : 64)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))

            Text("Change log (only frames that differ from the previous frame):")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(dmx.changeLog.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: dmx.changeLog.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .frame(minHeight: 100)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding()
    }

    private var modeDescription: String {
        if dmx.highSpeed {
            let r = dmx.debug.widgetRefresh.map { "\($0)" } ?? "?"
            return "HIGH SPEED — widget refresh \(r) (0 = as fast as possible), frames shrink to used channels (min \(EnttecPro.minChannels)), paced at DMX line time × \(DMXController.paceMargin)"
        }
        let r = dmx.debug.widgetRefresh.map { "\($0) Hz" } ?? "—"
        return "normal — full 512-channel frames at \(Int(dmx.frameRate)) fps, widget refresh \(r)"
    }

    private var frameDescription: String {
        let n = dmx.debug.frameChannels
        let line = EnttecPro.dmxLineTime(channels: n)
        return String(format: "%d channels · %d bytes over USB · %.2f ms on the DMX line (max %.0f fps)",
                      n, EnttecPro.packetBytes(channels: n), line * 1000, 1 / line)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private var packetHex: String {
        let pkt = dmx.debug.lastPacket
        guard !pkt.isEmpty else {
            // Show what *would* be sent, so the panel is useful even before connecting.
            let preview = EnttecPro.dmxPacket(universe: dmx.channels)
            return "(not connected — preview)\n" + hexDump(preview, full: showFullPacket)
        }
        return hexDump(pkt, full: showFullPacket)
    }

    private func hexDump(_ b: [UInt8], full: Bool) -> String {
        // Header (4) + start code (1) + channels + E7. Group as: header | startcode+channels | trailer.
        guard b.count >= 6 else { return b.map { String(format: "%02X", $0) }.joined(separator: " ") }
        let header = b[0..<4].map { String(format: "%02X", $0) }.joined(separator: " ")
        let start = String(format: "%02X", b[4])
        let channels = Array(b[5..<(b.count - 1)])
        let trailer = String(format: "%02X", b[b.count - 1])
        if !full {
            // Show through the last non-zero channel (min 16), then elide.
            let lastNZ = channels.lastIndex(where: { $0 != 0 }) ?? -1
            let n = min(channels.count, max(16, lastNZ + 1))
            let shown = channels[0..<n].map { String(format: "%02X", $0) }.joined(separator: " ")
            let elided = channels.count - n
            return "\(header) | \(start) \(shown)" + (elided > 0 ? " … (+\(elided) zero bytes)" : "") + " | \(trailer)   [\(b.count) bytes]"
        }
        var lines = ["\(header) | \(start)   ← header: SOM, label 6 (send DMX), length \(Int(b[2]) | (Int(b[3]) << 8)) LSB/MSB | start code"]
        var i = 0
        while i < channels.count {
            let chunk = channels[i..<min(i + 32, channels.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            lines.append(String(format: "ch%3d–%3d: ", i + 1, i + chunk.count) + hex)
            i += 32
        }
        lines.append("\(trailer)   ← EOM   [\(b.count) bytes total]")
        return lines.joined(separator: "\n")
    }

    private func byteString(_ n: Int) -> String {
        n < 1_000_000 ? String(format: "%.1f KB", Double(n) / 1000) : String(format: "%.2f MB", Double(n) / 1_000_000)
    }
}
