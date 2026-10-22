#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
VERIFY_DIR="${1:-$PROJECT_DIR/work/webkit-test}"
APP_DIR="$VERIFY_DIR/WKFixture.app"
rtk proxy mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
rtk proxy xcrun swiftc -swift-version 5 -D DEBUG -parse-as-library \
  -module-cache-path "${TMPDIR:-/tmp}/desktop-selector-module-cache" \
  "$PROJECT_DIR/Sources/CDP.swift" "$PROJECT_DIR/Sources/CaptureSession.swift" \
  "$PROJECT_DIR/Sources/WebKitConnection.swift" \
  "$PROJECT_DIR/Bridge/Sources/DomScanBridge/BridgeWire.swift" \
  "$PROJECT_DIR/Bridge/Sources/DomScanBridge/DomScanBridge.swift" \
  "$PROJECT_DIR/Tests/WKWebViewIntegration.swift" \
  -o "$APP_DIR/Contents/MacOS/WKFixture"
rtk proxy cp "$PROJECT_DIR/Resources/picker.js" "$APP_DIR/Contents/Resources/picker.js"
rtk proxy python3 "$PROJECT_DIR/Tests/run_webkit_test.py" "$APP_DIR" "${2:-test}"
