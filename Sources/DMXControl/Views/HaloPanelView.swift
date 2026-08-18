import SwiftUI
import DMXCore

/// Fixture panel for the amaran Halo 300x. Writes its encoded channels into the
/// universe whenever anything changes.
struct HaloPanelView: View {
    @EnvironmentObject var dmx: DMXController
    @State private var state = HaloState()
    @State private var profile: HaloProfile = .cctUniversal3ch
    @State private var startAddress: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("amaran Halo 300x").font(.headline)
                Spacer()
                Stepper("Address \(startAddress)", value: $startAddress, in: 1...(513 - profile.channelCount))
                    .fixedSize()
            }

            Picker("DMX Profile", selection: $profile) {
                ForEach(HaloProfile.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Text("Set the same profile on the light: Menu → DMX Mode → DMX Profile. Uses channels \(startAddress)–\(startAddress + profile.channelCount - 1).")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            LabeledSlider(title: "Intensity", value: $state.intensity, range: 0...100, format: "%.0f %%")

            LabeledSlider(title: "CCT", value: $state.cct,
                          range: HaloProfile.fixtureCCTRange, step: 50, format: "%.0f K")

            if profile == .cct5ch {
                LabeledSlider(title: "±Green", value: $state.greenMagenta, range: -100...100, step: 1,
                              format: "%+.0f")
                Toggle("CCT+ (extended range)", isOn: $state.cctPlus)
                    .toggleStyle(.switch)
            }

            Divider()

            HStack {
                Text("Strobe").frame(width: 80, alignment: .leading)
                Picker("", selection: $state.strobe) {
                    ForEach(StrobeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if state.strobe != .off {
                LabeledSlider(title: "Rate", value: $state.strobeRate, range: 0...1, format: "%.2f",
                              caption: "1 Hz → >25 Hz")
            }

            Divider()

            HStack {
                Button("Full") { state.intensity = 100 }
                Button("Half") { state.intensity = 50 }
                Button("Off")  { state.intensity = 0 }
                Spacer()
                Button("3200K") { state.cct = 3200 }
                Button("5600K") { state.cct = 5600 }
            }
            .buttonStyle(.bordered)

            let bytes = state.encode(profile: profile)
            Text("DMX out: " + bytes.enumerated().map { "ch\(startAddress + $0.offset)=\($0.element)" }.joined(separator: "  "))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .onChange(of: state) { _, _ in push() }
        .onChange(of: profile) { _, _ in push() }
        .onChange(of: startAddress) { _, _ in push() }
        .onAppear { push() }
    }

    private func push() {
        dmx.set(startingAt: startAddress, values: state.encode(profile: profile))
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.0f"
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).frame(width: 80, alignment: .leading)
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(String(format: format, value))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 70, alignment: .trailing)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 84)
            }
        }
    }
}
