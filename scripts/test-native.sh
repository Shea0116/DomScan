#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
VERIFY_DIR="${1:-$PROJECT_DIR/work/native-test}"
APP_DIR="$VERIFY_DIR/NativeFixture.app"
rtk proxy mkdir -p "$APP_DIR/Contents/MacOS"
rtk proxy xcrun swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "${TMPDIR:-/tmp}/desktop-selector-module-cache" \
  "$PROJECT_DIR/Sources/CDP.swift" "$PROJECT_DIR/Sources/CaptureSession.swift" \
  "$PROJECT_DIR/Sources/WebKitConnection.swift" "$PROJECT_DIR/Bridge/Sources/DomScanBridge/BridgeWire.swift" \
  "$PROJECT_DIR/Sources/ApplicationConnector.swift" "$PROJECT_DIR/Sources/DesktopWindowPicker.swift" \
  "$PROJECT_DIR/Sources/NativeCapture.swift" "$PROJECT_DIR/Tests/NativeCaptureIntegration.swift" \
  -o "$APP_DIR/Contents/MacOS/NativeFixture"
rtk proxy python3 - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'io.github.shea0116.domscan.nativefixture',
                  'CFBundleExecutable': 'NativeFixture', 'CFBundleName': 'NativeFixture',
                  'CFBundlePackageType': 'APPL'}, stream)
PY
rtk proxy codesign --force --sign - "$APP_DIR"
if [[ "${2:-test}" == serve ]]; then
  rtk proxy "$APP_DIR/Contents/MacOS/NativeFixture" --serve
else
  rtk proxy "$APP_DIR/Contents/MacOS/NativeFixture"
fi
