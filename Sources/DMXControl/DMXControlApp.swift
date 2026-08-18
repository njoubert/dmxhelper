import SwiftUI
import AppKit

@main
struct DMXControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var dmx = DMXController.shared

    var body: some Scene {
        WindowGroup("DMX Control") {
            ContentView()
                .environmentObject(dmx)
        }
        .defaultSize(width: 1320, height: 720)
    }
}

/// When run as a bare SwiftPM executable (no .app bundle) we have to promote
/// ourselves to a regular foreground app so the window and menu bar show up.
/// Also owns clean shutdown: the serial port must be closed *before* the process
/// exits, otherwise the kernel drains it lazily and the next launch blocks on open().
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Launch flags: `--high-speed` starts in high-speed mode, `--connect` connects immediately,
        // `--screenshot PATH` renders the window to a PNG after 3 s and quits (used for the README).
        let args = CommandLine.arguments
        if args.contains("--high-speed") { DMXController.shared.highSpeed = true }
        if args.contains("--connect") { DMXController.shared.connect() }
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.screenshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// Render the main window (frame + content) to a PNG. Uses the layer tree so AppKit
    /// control labels and the window background come out right; no screen-recording
    /// permission needed.
    private func screenshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let frameView = window.contentView?.superview else {
            FileHandle.standardError.write("screenshot: no window\n".data(using: .utf8)!); return
        }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        // Layer render is bottom-up in AppKit coordinates for non-flipped layers; the frame view's
        // layer is flipped, so flip the context to match.
        if frameView.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        frameView.layer?.render(in: ctx)
        guard let cg = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write("screenshot: wrote \(path) (\(w)×\(h))\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("screenshot: \(error)\n".data(using: .utf8)!)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DMXController.shared.shutdownSync()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
