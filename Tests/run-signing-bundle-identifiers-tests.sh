#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_BIN="${SWIFT_BIN:-$(command -v swiftc || true)}"
if [[ -z "$SWIFT_BIN" ]]; then echo "需要 Swift 6 編譯器；請設定 SWIFT_BIN。" >&2; exit 127; fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
# 只使用合成 Info.plist；不讀取帳戶、憑證、配對檔，也不呼叫 Apple。
"$SWIFT_BIN" -swift-version 6 -strict-concurrency=complete \
    Sources/EiliStore/SigningBundleIdentifiers.swift Tests/SigningBundleIdentifiersTests.swift -o "$build/tests"
"$build/tests"
