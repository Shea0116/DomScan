#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
VERIFY_DIR="${1:-$PROJECT_DIR/work/connection-ux-test}"
rtk proxy mkdir -p "$VERIFY_DIR"
rtk proxy xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "${TMPDIR:-/tmp}/desktop-selector-module-cache" \
  "$PROJECT_DIR/Sources/CDP.swift" "$PROJECT_DIR/Sources/CaptureSession.swift" \
  "$PROJECT_DIR/Sources/WebKitConnection.swift" "$PROJECT_DIR/Bridge/Sources/DomScanBridge/BridgeWire.swift" \
  "$PROJECT_DIR/Sources/ApplicationConnector.swift" "$PROJECT_DIR/Sources/NativeCapture.swift" "$PROJECT_DIR/Sources/DesktopWindowPicker.swift" \
  "$PROJECT_DIR/Tests/ConnectionUXIntegration.swift" -o "$VERIFY_DIR/connection-ux-test"
rtk proxy "$VERIFY_DIR/connection-ux-test"
