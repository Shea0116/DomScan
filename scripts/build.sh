#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${1:-${PROJECT_DIR:h}}"
APP_DIR="$OUTPUT_DIR/DomScan.app"
MODULE_CACHE="${SELECTOR_MODULE_CACHE_DIR:-${TMPDIR:-/tmp}/desktop-selector-module-cache}"
rtk proxy mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
rtk proxy xcrun swiftc -swift-version 5 -O -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -target "$(rtk proxy uname -m)-apple-macosx14.0" \
  "$PROJECT_DIR/Sources/CDP.swift" "$PROJECT_DIR/Sources/CaptureSession.swift" "$PROJECT_DIR/Sources/DomScanApp.swift" \
  "$PROJECT_DIR/Sources/ApplicationConnector.swift" "$PROJECT_DIR/Sources/DesktopWindowPicker.swift" "$PROJECT_DIR/Sources/ConnectionSidebar.swift" \
  -o "$APP_DIR/Contents/MacOS/DomScan"
rtk proxy cp "$PROJECT_DIR/Resources/picker.js" "$APP_DIR/Contents/Resources/picker.js"
rtk proxy cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
rtk proxy cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
rtk proxy cp "$PROJECT_DIR/Resources/BrandMark.png" "$APP_DIR/Contents/Resources/BrandMark.png"
rtk proxy codesign --force --sign - "$APP_DIR"
rtk proxy echo "Built: $APP_DIR"
