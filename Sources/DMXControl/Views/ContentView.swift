import SwiftUI
import DMXCore

struct ContentView: View {
    @EnvironmentObject var dmx: DMXController

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HSplitView {
                ScrollView { HaloPanelView() }
                    .frame(minWidth: 380, idealWidth: 420)
                ChannelGridView()
                    .frame(minWidth: 360)
                ScrollView { DebugView() }
                    .frame(minWidth: 420, idealWidth: 480)
            }
        }
        .frame(minWidth: 1180, minHeight: 620)
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Picker("Port", selection: $dmx.selectedPort) {
                ForEach(dmx.availablePorts, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag($0) }
                if dmx.availablePorts.isEmpty { Text("No serial ports").tag("") }
            }
            .frame(maxWidth: 260)
            .disabled(dmx.isConnected)

            Button { dmx.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(dmx.isConnected)
                .help("Rescan /dev/cu.*")

            if dmx.isConnected {
                Button("Disconnect") { dmx.disconnect() }
            } else {
                Button("Connect") { dmx.connect() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(dmx.selectedPort.isEmpty)
            }

            Circle()
                .fill(dmx.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(dmx.statusMessage).font(.caption)
                if !dmx.widgetInfo.isEmpty {
                    Text(dmx.widgetInfo).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if dmx.isConnected {
                Text("\(dmx.framesSent) frames · \(Int(dmx.frameRate)) fps")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}
