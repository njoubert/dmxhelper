// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import DMXCore

/// Fixture panel for the amaran Halo 300x. Writes its encoded channels into the
/// universe whenever anything changes.
struct HaloPanelView: View {
    @EnvironmentObject var dmx: DMXController
    @State private var state: HaloState
    @State private var profile: HaloProfile = .cctUniversal3ch
    @State private var startAddress: Int = 1

    init() {
        var s = HaloState()
        if CommandLine.arguments.contains("--demo") { s.intensity = 60; s.cct = 4500 }   // for screenshots
        _state = State(initialValue: s)
    }

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

            // Presets — wrap to the panel width; the active value is highlighted.
            VStack(alignment: .leading, spacing: 6) {
                Text("Intensity").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(Self.intensityPresets, id: \.value) { p in
                        PresetButton(label: p.label, isActive: state.intensity == p.value) { state.intensity = p.value }
                    }
                }
                Text("CCT").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(Self.cctPresets, id: \.self) { k in
                        PresetButton(label: "\(k)K", isActive: state.cct == Double(k)) { state.cct = Double(k) }
                    }
                }
            }

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

    /// Off, 10 % … Full in 10 % steps; 50 % is labelled "Half".
    static let intensityPresets: [(label: String, value: Double)] = (0...10).map { i in
        let v = Double(i * 10)
        switch i {
        case 0: return ("Off", v)
        case 5: return ("Half", v)
        case 10: return ("Full", v)
        default: return ("\(i * 10)%", v)
        }
    }

    /// Kelvin presets across the Halo's 2700–6500 K range (includes tungsten 3200 K and daylight 5600 K).
    static let cctPresets: [Int] = [2700, 3000, 3200, 3600, 4000, 4500, 5000, 5600, 6000, 6500]
}

/// Bordered button that turns prominent when its value is the current one.
struct PresetButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isActive {
                Button(action: action) { Text(label).frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Text(label).frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
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
