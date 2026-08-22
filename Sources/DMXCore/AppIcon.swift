// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import CoreGraphics

/// The app icon, drawn in code so it can be used as the live dock icon (the bare SwiftPM
/// executable has no bundle) and exported to an .iconset/.icns for `build.sh app`.
///
/// Design: a graphite macOS squircle holding three fader tracks — the DMX console idea —
/// filled with a 2700 K → 6500 K gradient, which is exactly the Halo's bi-color range.
public enum AppIcon {

    // MARK: Geometry, in a 1024-pt reference canvas (Apple's macOS icon grid:
    // 824×824 body centred in 1024, corner radius 185.4, shadow below).
    private static let ref: CGFloat = 1024
    private static let bodyInset: CGFloat = 100
    private static let bodyRadius: CGFloat = 185.4

    /// Draw the icon into `ctx`, scaled to `size` × `size` points.
    public static func draw(in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        let s = size / ref
        ctx.scaleBy(x: s, y: s)

        let body = CGRect(x: bodyInset, y: bodyInset, width: ref - 2 * bodyInset, height: ref - 2 * bodyInset)
        let shape = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

        // Drop shadow (baked in, the way macOS icons carry their own). Shadow offset and
        // blur are in base space — the CTM does not scale them — so they are scaled by hand,
        // or the shadow meant for the 1024 canvas is 44 device pixels at every size and gets
        // clipped to a hard line at the bottom of the 128-pt icon.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 44 * s,
                      color: NSColor(calibratedWhite: 0, alpha: 0.42).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()

        // Body: graphite, lit from the top.
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        fillLinear(ctx, from: CGPoint(x: 512, y: body.maxY), to: CGPoint(x: 512, y: body.minY),
                   stops: [(0.0, rgb(0x39, 0x40, 0x4E)), (0.55, rgb(0x1E, 0x22, 0x2B)), (1.0, rgb(0x0E, 0x10, 0x15))],
                   rect: body)

        // Warm bloom behind the faders, as if the light is on.
        drawGlow(ctx, center: CGPoint(x: 512, y: 470), radius: 430,
                 color: rgb(0xFF, 0xA8, 0x4D), alpha: 0.20)

        drawFaders(ctx)

        // Top edge highlight along the squircle.
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.14).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    /// Three capsule tracks with fills at different levels, under one warm→cool gradient.
    private static func drawFaders(_ ctx: CGContext) {
        let area = CGRect(x: 260, y: 258, width: 504, height: 508)
        let w: CGFloat = 124
        let gap = (area.width - 3 * w) / 2
        let levels: [CGFloat] = [0.42, 0.88, 0.62]   // fader positions, left → right

        // Dim tracks.
        for i in 0..<3 {
            let x = area.minX + CGFloat(i) * (w + gap)
            let track = CGRect(x: x, y: area.minY, width: w, height: area.height)
            ctx.addPath(CGPath(roundedRect: track, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor)
            ctx.fillPath()
        }

        // Bright fills, clipped as one shape so a single gradient spans all three.
        ctx.saveGState()
        let fills = CGMutablePath()
        for (i, level) in levels.enumerated() {
            let x = area.minX + CGFloat(i) * (w + gap)
            let h = max(w, area.height * level)
            fills.addRoundedRect(in: CGRect(x: x, y: area.minY, width: w, height: h),
                                 cornerWidth: w / 2, cornerHeight: w / 2)
        }
        ctx.addPath(fills); ctx.clip()
        // 2700 K tungsten on the left → neutral → 6500 K daylight on the right.
        fillLinear(ctx, from: CGPoint(x: area.minX, y: 0), to: CGPoint(x: area.maxX, y: 0),
                   stops: [(0.0, rgb(0xFF, 0x9A, 0x3D)), (0.5, rgb(0xFF, 0xEB, 0xCF)), (1.0, rgb(0x6F, 0xB2, 0xFF))],
                   rect: area)
        ctx.restoreGState()

    }

    // MARK: Drawing helpers

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func fillLinear(_ ctx: CGContext, from: CGPoint, to: CGPoint,
                                   stops: [(CGFloat, CGColor)], rect: CGRect) {
        let colors = stops.map { $0.1 } as CFArray
        let locations = stops.map { $0.0 }
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat) {
        let c = color.copy(alpha: alpha)!
        let clear = color.copy(alpha: 0)!
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c, clear] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Rasterising

    /// Render to a bitmap of `px` × `px` pixels.
    public static func cgImage(px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        draw(in: ctx, size: CGFloat(px))
        return ctx.makeImage()
    }

    public static func pngData(px: Int) -> Data? {
        guard let cg = cgImage(px: px) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// An NSImage suitable for `NSApp.applicationIconImage`.
    public static func nsImage(px: Int = 512) -> NSImage? {
        guard let cg = cgImage(px: px) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: px, height: px))
    }

    /// Write an .iconset directory (feed it to `iconutil -c icns`).
    @discardableResult
    public static func writeIconset(to dir: String) throws -> String {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // (base points, scale) pairs required by iconutil.
        let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                      (256, 1), (256, 2), (512, 1), (512, 2)]
        for (pt, scale) in variants {
            let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
            guard let data = pngData(px: pt * scale) else { continue }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return dir
    }
}
