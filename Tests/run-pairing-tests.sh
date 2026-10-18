#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null 2>&1; then
    echo "需要 Swift 編譯器；未執行測試。" >&2
    exit 2
fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
		    Sources/EiliStore/PairingFileStore.swift Sources/EiliStore/PairingFileAnnotation.swift Tests/PairingFileStoreTests.swift \
    -o "$build/pairing-tests"
"$build/pairing-tests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    Sources/EiliStore/PairingFileStore.swift Sources/EiliStore/PairingFileAnnotation.swift \
    Sources/EiliStore/PairingFieldDisclosure.swift Tests/PairingFieldDisclosureTests.swift \
    -o "$build/disclosure-tests"
"$build/disclosure-tests"
