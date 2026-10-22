#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
TEST_BUILD_DIR="$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/desktop-selector-test.XXXXXX")"
trap 'rtk proxy rm -rf "$TEST_BUILD_DIR"' EXIT
rtk proxy xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "${TMPDIR:-/tmp}/desktop-selector-module-cache" \
  "$PROJECT_DIR/Sources/CDP.swift" "$PROJECT_DIR/Sources/CaptureSession.swift" "$PROJECT_DIR/Sources/WebKitConnection.swift" "$PROJECT_DIR/Bridge/Sources/DomScanBridge/BridgeWire.swift" "$PROJECT_DIR/Tests/Integration.swift" \
  -o "$TEST_BUILD_DIR/integration-test"
rtk proxy "$TEST_BUILD_DIR/integration-test" "$PROJECT_DIR/Resources/picker.js" "${1:-http://127.0.0.1:9445}" "${2:-$TEST_BUILD_DIR/reports}"
