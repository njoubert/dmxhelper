// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// amaran Halo 300x (bi-color COB, 2700K–6500K).
///
/// Channel maps from "amaran DMX Profile Specification V1.1 (March 2026)",
/// see docs/amaran-dmx-profile-spec-v1.1.pdf. The Halo x-series is bi-color,
/// so only the CCT profiles apply:
///
///   Profile 1 – CCT Universal – 8Bit (3ch): Intensity, CCT (2700–6500K), Strobe
///   Profile 2 – CCT – 8Bit (5ch):           Intensity, CCT (2300–10000K), ±Green, Strobe, CCT+
///
/// Select the profile on the light: Menu → DMX Mode → DMX Profile.
public enum HaloProfile: String, CaseIterable, Identifiable {
    case cctUniversal3ch = "Profile 1 · CCT Universal (3ch)"
    case cct5ch          = "Profile 2 · CCT (5ch)"

    public var id: String { rawValue }

    public var channelCount: Int {
        switch self {
        case .cctUniversal3ch: return 3
        case .cct5ch: return 5
        }
    }

    /// Kelvin range the CCT channel spans (0…255) in this profile.
    public var cctRange: ClosedRange<Double> {
        switch self {
        case .cctUniversal3ch: return 2700...6500
        case .cct5ch: return 2300...10000
        }
    }

    /// What the fixture can physically produce; used to clamp the UI slider.
    public static let fixtureCCTRange: ClosedRange<Double> = 2700...6500
}

public enum StrobeMode: String, CaseIterable, Identifiable {
    case off = "Off", random = "Random", constant = "Constant"
    public var id: String { rawValue }
}

/// UI-level parameters for the Halo, converted to raw DMX bytes by `encode(profile:)`.
public struct HaloState: Equatable {
    public var intensity: Double = 0            // 0…100 %
    public var cct: Double = 3200               // Kelvin
    public var greenMagenta: Double = 0         // -100…+100 (0 = neutral); Profile 2 only
    public var strobe: StrobeMode = .off
    public var strobeRate: Double = 0           // 0…1 → 1Hz…>25Hz within the chosen mode band
    public var cctPlus: Bool = false            // Profile 2 only

    public init() {}

    /// DMX byte values for the given profile, starting at the fixture's start address.
    public func encode(profile: HaloProfile) -> [UInt8] {
        let intensityByte = UInt8((intensity / 100 * 255).rounded().clamped(0, 255))

        let r = profile.cctRange
        let cctNorm = ((cct - r.lowerBound) / (r.upperBound - r.lowerBound)).clamped(0, 1)
        let cctByte = UInt8((cctNorm * 255).rounded())

        // Strobe: 0–13 off, 14–128 random (1Hz→>25Hz), 129–255 constant (1Hz→>25Hz).
        let strobeByte: UInt8
        switch strobe {
        case .off:      strobeByte = 0
        case .random:   strobeByte = UInt8((14 + strobeRate.clamped(0, 1) * (128 - 14)).rounded())
        case .constant: strobeByte = UInt8((129 + strobeRate.clamped(0, 1) * (255 - 129)).rounded())
        }

        switch profile {
        case .cctUniversal3ch:
            return [intensityByte, cctByte, strobeByte]

        case .cct5ch:
            // ±Green: 0–10 "no effect" (don't use), 11–20 full minus, 21–119 -99…-1,
            // 120–145 neutral, 146–244 +1…+99, 245–255 full plus.
            let g = greenMagenta.clamped(-100, 100)
            let greenByte: UInt8
            if g <= -100 { greenByte = 15 }
            else if g < 0 { greenByte = UInt8((21 + (g + 99) / 98 * (119 - 21)).rounded()) }   // -99→21, -1→119
            else if g == 0 { greenByte = 133 }
            else if g < 100 { greenByte = UInt8((146 + (g - 1) / 98 * (244 - 146)).rounded()) } //  1→146, 99→244
            else { greenByte = 250 }
            let cctPlusByte: UInt8 = cctPlus ? 255 : 0
            return [intensityByte, cctByte, greenByte, strobeByte, cctPlusByte]
        }
    }
}

public extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
