#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x /workspace/tooling/swift603/usr/bin/swiftc ]]; then
    export PATH="/workspace/tooling/swift603/usr/bin:$PATH"
fi
SWIFTC="${SWIFTC:-$(command -v swiftc || true)}"
CLANG="${CLANG:-$(command -v clang || command -v cc || true)}"
[[ -x "$SWIFTC" ]] || { echo "swiftc required" >&2; exit 2; }
[[ -x "$CLANG" ]] || { echo "clang or cc required" >&2; exit 2; }
cd "$repo_root"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
"$CLANG" -std=c11 -D_POSIX_C_SOURCE=200809L -ITests/Fixtures \
    -c Tests/Fixtures/AFCTestFFI.c -o "$build/AFCTestFFI.o"
"$SWIFTC" -swift-version 5 -parse-as-library \
    -I Tests/Fixtures/AFCTestFFI \
    Sources/EiliStore/RustAFCClient.swift \
    Sources/EiliStore/InstallerTransferGate.swift \
    Sources/EiliStore/IPAStagingPaths.swift \
    Tests/Fixtures/RustAFCClientTestSupport.swift \
    Tests/RustAFCClientInstallGateTests.swift \
    "$build/AFCTestFFI.o" -o "$build/afc-installer-regression-tests"
"$build/afc-installer-regression-tests"
