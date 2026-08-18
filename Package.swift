// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DMXControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DMXCore", targets: ["DMXCore"]),
        .executable(name: "DMXControl", targets: ["DMXControl"]),
        .executable(name: "dmxcli", targets: ["dmxcli"]),
    ],
    targets: [
        // Serial port, Enttec DMX USB Pro protocol, fixture profiles.
        .target(name: "DMXCore"),
        // SwiftUI app.
        .executableTarget(
            name: "DMXControl",
            dependencies: ["DMXCore"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        // Tiny CLI for scripting / smoke testing.
        .executableTarget(name: "dmxcli", dependencies: ["DMXCore"]),
    ]
)
