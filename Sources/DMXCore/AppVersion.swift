// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What version is this? The first thing a bug report needs, so the app shows it in the
/// connection bar and `dmxcli version` prints it.
///
/// Both numbers come from the bundle's Info.plist, which `build.sh` writes:
/// `CFBundleShortVersionString` is the marketing version (`VERSION=` in build.sh) and
/// `CFBundleVersion` is `git rev-list --count HEAD`, so it pins a build to exact source.
/// A bare SwiftPM binary (`./build.sh run`, `dmxcli`) has no bundle and honestly says so.
public enum AppVersion {

    public static var displayName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Nimbus DMX Helper"
    }

    /// "v1.0 (27)", or "dev build" when running outside an .app bundle.
    public static var versionString: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "dev build" }
        guard let build = info?["CFBundleVersion"] as? String else { return "v\(short)" }
        return "v\(short) (\(build))"
    }

    public static var full: String { "\(displayName) \(versionString)" }
}
