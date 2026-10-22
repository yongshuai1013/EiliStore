#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$ROOT/Tests/SettingsNavigationUI"
BUILD_DIR="$ROOT/build"
PROJECT="$BUILD_DIR/SettingsNavigationUI.xcodeproj"
RESULT="$BUILD_DIR/settings-navigation-ui.xcresult"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This UI test runner requires macOS and Xcode." >&2
  exit 2
fi
command -v xcodegen >/dev/null || { echo "xcodegen is required (install it in CI before running)." >&2; exit 2; }
command -v xcodebuild >/dev/null || { echo "xcodebuild is required." >&2; exit 2; }
mkdir -p "$BUILD_DIR"
rm -rf "$RESULT" "$PROJECT" "$TEST_DIR/build"
mkdir -p "$TEST_DIR/build"

python3 - "$ROOT/Sources/EiliStore/EiliStoreApp.swift" "$TEST_DIR/build/ExtractedNavigation.swift" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
def extract(declaration):
    start = source.find(declaration)
    if start < 0:
        raise SystemExit(f"Could not find {declaration!r} in production app source")
    opening = source.find('{', start)
    depth = 0
    in_string = False
    escaped = False
    line_comment = False
    block_depth = 0
    i = opening
    while i < len(source):
        c = source[i]
        n = source[i+1] if i+1 < len(source) else ''
        if line_comment:
            if c == '\n': line_comment = False
        elif block_depth:
            if c == '/' and n == '*': block_depth += 1; i += 1
            elif c == '*' and n == '/': block_depth -= 1; i += 1
        elif in_string:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': in_string = False
        elif c == '/' and n == '/': line_comment = True; i += 1
        elif c == '/' and n == '*': block_depth = 1; i += 1
        elif c == '"': in_string = True
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: return source[start:i+1]
        i += 1
    raise SystemExit(f"Unbalanced declaration: {declaration}")
parts = ['import SwiftUI', extract('struct MainTabView: View'), extract('struct SettingsView: View')]
Path(sys.argv[2]).write_text('\n\n'.join(parts) + '\n')
PY

xcodegen generate --spec "$TEST_DIR/project.yml" --project "$BUILD_DIR"
DEVICE="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if "iPhone" in v["name"] and v.get("isAvailable",False)),""))')"
if [[ -z "$DEVICE" ]]; then echo "No available iPhone simulator found." >&2; exit 2; fi
set +e
xcodebuild test -project "$PROJECT" -scheme SettingsNavigationHarness -destination "platform=iOS Simulator,id=$DEVICE" -derivedDataPath "$BUILD_DIR/SettingsNavigationDerivedData" -resultBundlePath "$RESULT" 2>&1 | tee "$BUILD_DIR/settings-navigation-ui.log"
TEST_STATUS=${PIPESTATUS[0]}
set -e

# Attachment export is best-effort and must never mask the XCTest status.
if [[ -d "$RESULT" ]]; then
  mkdir -p "$BUILD_DIR/settings-navigation-screenshots"
  if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$BUILD_DIR/settings-navigation-screenshots" >/dev/null 2>&1; then
    echo "Exported result attachments to $BUILD_DIR/settings-navigation-screenshots"
  else
    echo "xcresulttool attachment export unavailable/failed; screenshots remain in $RESULT" >&2
  fi
fi
exit "$TEST_STATUS"
