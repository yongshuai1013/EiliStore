#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-$(command -v swiftc || true)}"
CLANG="${CLANG:-$(command -v clang || command -v cc || true)}"
HEADER="${IDEVICE_HEADER:-Libraries/IDeviceFFI.xcframework/ios-arm64/Headers/idevice.h}"
if [[ ! -x "$SWIFTC" ]]; then
    echo "Swift 6 compiler not found: $SWIFTC" >&2
    exit 2
fi
if [[ "$HEADER" != /* ]]; then HEADER="$PWD/$HEADER"; fi
if [[ ! -x "$CLANG" ]]; then
    echo "C compiler not found; set CLANG." >&2
    exit 2
fi
if [[ ! -f "$HEADER" || ! -f "$(dirname "$HEADER")/module.modulemap" ]]; then
    echo "Set IDEVICE_HEADER to the pinned idevice.h (with its module.modulemap alongside it); no network fallback is used." >&2
    exit 2
fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
"$CLANG" -std=c11 -Wno-deprecated-declarations -I "$(dirname "$HEADER")" -c Tests/Fixtures/TransportFakeC.c -o "$build/TransportFakeC.o"
"$SWIFTC" -swift-version 6 -strict-concurrency=complete -parse-as-library -I "$(dirname "$HEADER")" \
    Sources/EiliStore/PairingFileStore.swift Sources/EiliStore/PairingFileAnnotation.swift \
    Sources/EiliStore/RustLoggingPrivacy.swift Sources/EiliStore/RustDeviceTransport.swift \
    Tests/RustDeviceTransportTests.swift "$build/TransportFakeC.o" -o "$build/transport-tests"
"$build/transport-tests"
TEST_LOGGER_FAILURE=1 "$build/transport-tests"
# Compile the heartbeat gateway against a minimal protocol surface and the pinned C header.
cat > "$build/HeartbeatGateway.swift" <<'SWIFT'
import Foundation
public protocol HeartbeatGateway: AnyObject {
    var servicePort: UInt16 { get }
    func performHeartbeat(interval: UInt64) async throws -> UInt64
}
SWIFT
"$SWIFTC" -swift-version 5 -typecheck -I "$(dirname "$HEADER")" \
    Sources/EiliStore/PairingFileStore.swift Sources/EiliStore/PairingFileAnnotation.swift \
    Sources/EiliStore/RustFFILock.swift Sources/EiliStore/RustLoggingPrivacy.swift \
    Sources/EiliStore/RustDeviceTransport.swift Sources/EiliStore/RustHeartbeatGateway.swift \
    "$build/HeartbeatGateway.swift"
