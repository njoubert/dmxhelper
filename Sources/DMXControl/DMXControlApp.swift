import SwiftUI
import DMXCore
import AppKit

@main
struct DMXControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var dmx = DMXController()

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
