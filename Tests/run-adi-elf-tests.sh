#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWIFTC=$(command -v swiftc || true)
if [ -x /workspace/tooling/swift603/usr/bin/swiftc ]; then SWIFTC=/workspace/tooling/swift603/usr/bin/swiftc; fi
: "${SWIFTC:?swiftc not found}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
"$SWIFTC" -swift-version 6 "$ROOT/Sources/EiliStore/ADIElfMetadata.swift" "$ROOT/Tests/Fixtures/ADIElfFixture.swift" "$ROOT/Tests/ADIElfMetadataTests.swift" -o "$TMP/tests"
"$TMP/tests"
"$SWIFTC" -swift-version 6 "$ROOT/Sources/EiliStore/ADIElfMetadata.swift" "$ROOT/Sources/EiliStore/ADILibraryCompatibility.swift" \
  "$ROOT/Tests/Fixtures/ADIElfFixture.swift" "$ROOT/Tests/ADILibraryCompatibilityTests.swift" -o "$TMP/compatibility-tests"
"$TMP/compatibility-tests"
"$SWIFTC" -swift-version 6 "$ROOT/Packages/AnisetteKit/Sources/Constants.swift" \
  "$ROOT/Packages/AnisetteKit/Sources/AnisetteError.swift" "$ROOT/Packages/AnisetteKit/Sources/AnisetteDataResponse.swift" \
  "$ROOT/Tests/AnisetteResponseParityTests.swift" -o "$TMP/response-parity-tests"
"$TMP/response-parity-tests"
