#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_BIN="${SWIFT_BIN:-$(command -v swiftc || true)}"
if [[ -z "$SWIFT_BIN" ]]; then echo "需要 Swift 6 編譯器；請設定 SWIFT_BIN。" >&2; exit 127; fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
# 離線契約測試：使用測試替身，不會登入或呼叫 Apple，也不代表完整 iOS 建置。
"$SWIFT_BIN" -swift-version 6 -strict-concurrency=complete -parse-as-library -emit-module -emit-object -module-name SideSign \
    Tests/Fixtures/PortalServiceSideSignStub.swift -o "$build/SideSign.o" -emit-module-path "$build/SideSign.swiftmodule"
"$SWIFT_BIN" -swift-version 6 -strict-concurrency=complete -I "$build" \
    Sources/EiliStore/DeveloperPortalValidation.swift Sources/EiliStore/DeveloperPortalService.swift \
    Tests/Fixtures/PaxSigningServiceStub.swift Tests/DeveloperPortalServiceTests.swift "$build/SideSign.o" -o "$build/tests"
"$build/tests"
