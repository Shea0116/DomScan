#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
VERIFY_DIR="${1:-$(rtk proxy mktemp -d /private/tmp/ds-report.XXXXXX)}"
MODULE_CACHE="${SELECTOR_MODULE_CACHE_DIR:-${TMPDIR:-/tmp}/desktop-selector-module-cache}"
rtk proxy mkdir -p "$VERIFY_DIR" "$MODULE_CACHE"
COMMON=("$PROJECT_DIR/Sources/CDP.swift" "$PROJECT_DIR/Sources/CaptureSession.swift")
ENTRY=("$PROJECT_DIR/Sources/ApplicationConnector.swift" "$PROJECT_DIR/Sources/DesktopWindowPicker.swift")
rtk proxy xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "${COMMON[@]}" "${ENTRY[@]}" "$PROJECT_DIR/Tests/EngineEntryIntegration.swift" -o "$VERIFY_DIR/engine-entry-test"
rtk proxy xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "${COMMON[@]}" "${ENTRY[@]}" "$PROJECT_DIR/Tests/InspectionLaunchIntegration.swift" -o "$VERIFY_DIR/inspection-launch-test"
rtk proxy xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "${COMMON[@]}" "$PROJECT_DIR/Tests/Integration.swift" -o "$VERIFY_DIR/integration-test"
rtk proxy env SELECTOR_RUN_LAUNCH_TEST=1 python3 "$PROJECT_DIR/Tests/run_renamed_engine_test.py" "$VERIFY_DIR"
