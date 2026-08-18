import SwiftUI
import DMXCore

/// Raw access to all 512 channels.
struct ChannelGridView: View {
    @EnvironmentObject var dmx: DMXController
    @State private var visibleCount = 32
    @State private var filter = ""

    private var channelsToShow: [Int] {
        if let n = Int(filter.trimmingCharacters(in: .whitespaces)), (1...512).contains(n) { return [n] }
        return Array(1...visibleCount)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Channels").font(.headline)
                Spacer()
                TextField("Go to ch…", text: $filter).frame(width: 90).textFieldStyle(.roundedBorder)
                Picker("Show", selection: $visibleCount) {
                    Text("1–32").tag(32)
                    Text("1–64").tag(64)
                    Text("1–128").tag(128)
                    Text("1–512").tag(512)
                }.pickerStyle(.menu).fixedSize()
                Button("Blackout") { dmx.blackout() }
                Button("Full") { dmx.fullOn() }
            }
            .padding([.horizontal, .top])

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(channelsToShow, id: \.self) { ch in
                        ChannelRow(channel: ch)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct ChannelRow: View {
    @EnvironmentObject var dmx: DMXController
    let channel: Int

    var body: some View {
        let v = dmx.value(of: channel)
        HStack(spacing: 8) {
            Text(String(format: "%3d", channel))
                .font(.system(.body, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
            Slider(value: Binding(
                get: { Double(v) },
                set: { dmx.set(channel: channel, value: UInt8($0.rounded())) }
            ), in: 0...255)
            Text(String(format: "%3d", v))
                .font(.system(.body, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
            Rectangle()
                .fill(Color.orange.opacity(Double(v) / 255))
                .frame(width: 18, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.4)))
                .cornerRadius(2)
        }
    }
}
