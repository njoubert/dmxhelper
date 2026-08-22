// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import DMXCore

/// Live picture of what the widget hears on its DMX IN port.
///
/// Receiving is a mode on the DMX USB Pro, not a second channel: while this is on the widget
/// stops driving DMX OUT, and the fixtures hold whatever they last got.
struct MonitorView: View {
    @EnvironmentObject var dmx: DMXController

    private static let perRow = 16

    /// Level → colour: dark red at the bottom of the fader, orange through the middle, white at full.
    static func heat(_ v: UInt8) -> Color {
        guard v > 0 else { return Color.gray.opacity(0.10) }
        let t = Double(v) / 255
        return Color(hue: 0.075 - 0.02 * t,
                     saturation: max(0, 1 - pow(t, 2.4) * 0.95),
                     brightness: 0.34 + 0.66 * t)
    }

    /// Rows to draw: through the highest slot ever lit, rounded up, at least four rows.
    private var shownSlots: Int {
        let lit = max(dmx.input.highestLit, 1)
        let rounded = ((lit + Self.perRow - 1) / Self.perRow) * Self.perRow
        return min(512, max(Self.perRow * 4, rounded))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if dmx.monitoring {
                stats
                grid
            } else {
                idle
            }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top])
    }

    private var header: some View {
        HStack {
            Text("DMX In").font(.headline)
            statusPill
            Spacer()
            Toggle("Listen", isOn: $dmx.monitoring)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!dmx.isConnected)
                .help("Put the widget into receive mode. It stops transmitting while it listens — the Pro can't do both.")
        }
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if !dmx.isConnected { return ("not connected", .secondary) }
            if !dmx.monitoring { return ("transmitting", .secondary) }
            if dmx.input.live { return ("receiving", .green) }
            return (dmx.input.lastFrameAt == nil ? "no signal" : "signal lost", .orange)
        }()
        return Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The widget's IN port is idle until you switch it to listening.")
                .font(.callout)
            Text("Turning this on stops output: the Pro transmits or receives, never both. "
                 + "Feed the IN port from a console, an Art-Net/sACN node, or another widget's OUT.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var stats: some View {
        let i = dmx.input
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 14) {
                stat("fps", String(format: "%.0f", i.fps))
                stat("frames", "\(i.frames + i.deltas)")
                stat("slots", i.slotCount > 0 ? "\(i.slotCount)" : "—")
                stat("start", i.startCode.map { String(format: "0x%02X", $0) } ?? "—")
                stat("lit", "\(i.slots.prefix(max(i.highestLit, 1)).filter { $0 != 0 }.count)")
            }
            if i.overflows + i.overruns + i.otherMessages + i.resyncs > 0 {
                Text("overflow \(i.overflows) · overrun \(i.overruns) · other messages \(i.otherMessages) · resyncs \(i.resyncs)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange)
            }
            if let code = i.startCode, code != 0 {
                Text("start code 0x\(String(format: "%02X", code)) — not ordinary dimmer data")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange)
            }
            if i.lastFrameAt == nil {
                Text("nothing on the line yet — patch a DMX source into the widget's IN port")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private var grid: some View {
        let i = dmx.input
        let now = Date()
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(stride(from: 0, to: shownSlots, by: Self.perRow)), id: \.self) { row in
                    HStack(spacing: 2) {
                        Text("\(row + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        ForEach(row..<min(row + Self.perRow, 512), id: \.self) { slot in
                            cell(value: i.slots[slot], fresh: now.timeIntervalSince(i.lastChange[slot]) < 0.35)
                        }
                    }
                }
                if shownSlots < 512 {
                    Text("slots \(shownSlots + 1)–512 never lit")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cell(value: UInt8, fresh: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(MonitorView.heat(value))
            .frame(height: 17)
            .frame(maxWidth: .infinity)
            .overlay(
                Text(value == 0 ? "" : "\(value)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(value > 150 ? Color.black : Color.white.opacity(0.9))
            )
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(fresh ? 0.55 : 0), lineWidth: 1))
    }
}
