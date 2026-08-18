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
        // Launch flags: `--high-speed` starts in high-speed mode, `--connect` connects immediately.
        let args = CommandLine.arguments
        if args.contains("--high-speed") { DMXController.shared.highSpeed = true }
        if args.contains("--connect") { DMXController.shared.connect() }
        // Ctrl-C / kill in the launching terminal → orderly quit instead of instant death.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DMXController.shared.shutdownSync()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
