#!/usr/bin/env bash
# Build & run helpers for the DMX toy.
#
#   ./build.sh            build everything (debug)
#   ./build.sh run        build, then launch the SwiftUI app (extra args pass through:
#                         --connect auto-connects, --high-speed starts in high-speed mode,
#                         --monitor listens on DMX IN instead of transmitting)
#   ./build.sh app        build a release DMXControl.app bundle in ./dist and open it
#   ./build.sh install    build the bundle and install it into /Applications
#   ./build.sh cli ...    build, then run dmxcli with the given args   (e.g. ./build.sh cli halo 50 3200)
#   ./build.sh icon       re-render docs/icon.png from Sources/DMXCore/AppIcon.swift
#   ./build.sh clean      remove build products
set -euo pipefail
cd "$(dirname "$0")"

APP=dist/DMXControl.app

# Release build → ./dist/DMXControl.app, ad-hoc signed, icon baked in.
build_app() {
  swift build -c release --product DMXControl
  swift build -c release --product dmxcli
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build/release/DMXControl "$APP/Contents/MacOS/DMXControl"
  # Icon: rendered by code (Sources/DMXCore/AppIcon.swift) → .iconset → .icns
  .build/release/dmxcli icon --iconset dist/AppIcon.iconset >/dev/null
  iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf dist/AppIcon.iconset
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DMX Control</string>
  <key>CFBundleDisplayName</key><string>DMX Control</string>
  <key>CFBundleIdentifier</key><string>com.njoubert.dmxcontrol</string>
  <key>CFBundleExecutable</key><string>DMXControl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
}

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
    build_app
    open "$APP"
    ;;
  install)
    build_app
    DEST=/Applications/DMXControl.app
    # A running copy would hold the serial port (and its own binary) — stop it first.
    pkill -x DMXControl 2>/dev/null && sleep 1 || true
    [ -e "$DEST" ] && echo "replacing existing $DEST" || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "installed → $DEST   (open with: open -a 'DMX Control')"
    ;;
  icon)
    swift build --product dmxcli >/dev/null
    .build/debug/dmxcli icon --png docs/icon.png --size 512
    ;;
  clean)
    rm -rf .build dist
    ;;
  *)
    echo "usage: $0 [build|run|app|install|cli <args>|icon|clean]" >&2
    exit 2
    ;;
esac
