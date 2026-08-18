#!/usr/bin/env bash
# Build & run helpers for the DMX toy.
#
#   ./build.sh            build everything (debug)
#   ./build.sh run        build, then launch the SwiftUI app (extra args pass through:
#                         --connect auto-connects, --high-speed starts in high-speed mode)
#   ./build.sh app        build a release DMXControl.app bundle in ./dist and open it
#   ./build.sh cli ...    build, then run dmxcli with the given args   (e.g. ./build.sh cli halo 50 3200)
#   ./build.sh clean      remove build products
set -euo pipefail
cd "$(dirname "$0")"

cmd="${1:-build}"
[ $# -gt 0 ] && shift

case "$cmd" in
  build)
    swift build
    echo "ok → .build/debug/DMXControl, .build/debug/dmxcli"
    ;;
  run)
    swift build
    exec .build/debug/DMXControl "$@"
    ;;
  cli)
    swift build --product dmxcli >/dev/null
    exec .build/debug/dmxcli "$@"
    ;;
  app)
    swift build -c release --product DMXControl
    APP=dist/DMXControl.app
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp .build/release/DMXControl "$APP/Contents/MacOS/DMXControl"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DMX Control</string>
  <key>CFBundleDisplayName</key><string>DMX Control</string>
  <key>CFBundleIdentifier</key><string>com.njoubert.dmxcontrol</string>
  <key>CFBundleExecutable</key><string>DMXControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "built $APP"
    open "$APP"
    ;;
  clean)
    rm -rf .build dist
    ;;
  *)
    echo "usage: $0 [build|run|app|cli <args>|clean]" >&2
    exit 2
    ;;
esac
