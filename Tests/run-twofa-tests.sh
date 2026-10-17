#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null 2>&1; then
    echo "需要 Swift 6 編譯器；未執行測試。" >&2
    exit 2
fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
# 只替代 provider 用到的公開資料型別；不編譯／呼叫任何網路、認證或 Keychain 程式。
# 型別契約對照 SideSign e9363621dbc8b780db281f4bf57e4a7418e56753。
cat > "$build/SideSign.swift" <<'SWIFT'
public enum TwoFactorDeliveryMode: String, Sendable, CaseIterable {
    case trustedDevice, sms, voice
}
public struct TrustedPhoneNumber: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let number: String
    public init(id: String, number: String) { self.id = id; self.number = number }
}
SWIFT
swiftc -swift-version 6 -parse-as-library -emit-module -emit-object -module-name SideSign \
    -emit-module-path "$build/SideSign.swiftmodule" "$build/SideSign.swift" -o "$build/SideSign.o"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -I "$build" \
    Sources/EiliStore/TwoFACodeProvider.swift Tests/TwoFACodeProviderTests.swift \
    "$build/SideSign.o" -o "$build/provider-tests"
"$build/provider-tests"
