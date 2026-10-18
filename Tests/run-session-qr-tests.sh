#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
    echo "需要 macOS 與 Swift 編譯器（Core Image / Vision）；未執行測試。" >&2
    exit 2
fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
swiftc -swift-version 5 -parse-as-library \
    Sources/EiliStore/SessionQRCode.swift Tests/SessionQRCodeTests.swift \
    -o "$build/session-qr-tests"
"$build/session-qr-tests"
