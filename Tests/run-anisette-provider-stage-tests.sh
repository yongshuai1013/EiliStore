#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWIFT_BIN="${SWIFT_BIN:-}"
if [ -z "$SWIFT_BIN" ] && [ -x /workspace/tooling/swift603/usr/bin/swiftc ]; then
    SWIFT_BIN=/workspace/tooling/swift603/usr/bin
fi
if [ -n "$SWIFT_BIN" ]; then
    case "$SWIFT_BIN" in */swiftc) SWIFTC=$SWIFT_BIN ;; *) SWIFTC=$SWIFT_BIN/swiftc ;; esac
    PATH="$(dirname "$SWIFTC"):$PATH"
    export PATH
else
    SWIFTC=$(command -v swiftc)
fi
CC=${CC:-$(command -v clang || command -v cc)}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/anisette-stage.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/module"
cat > "$TMP/module/module.modulemap" <<EOF
module anisette_core [system] {
    header "$ROOT/Packages/AnisetteKit/Native/include/anisette_core.h"
    export *
}
EOF
"$CC" -std=c11 -Wall -Wextra -Werror -I "$ROOT/Packages/AnisetteKit/Native/include" -c "$ROOT/Tests/Fixtures/AnisetteProviderStageStub.c" -o "$TMP/stub.o"
"$SWIFTC" -swift-version 6 -strict-concurrency=complete -I "$TMP/module" \
    "$ROOT/Packages/AnisetteKit/Sources/Constants.swift" \
    "$ROOT/Packages/AnisetteKit/Sources/AnisetteError.swift" \
    "$ROOT/Packages/AnisetteKit/Sources/AnisetteDataResponse.swift" \
    "$ROOT/Packages/AnisetteKit/Sources/AnisetteDataProvider.swift" \
    "$ROOT/Tests/AnisetteProviderStageTests.swift" "$TMP/stub.o" -o "$TMP/stage-tests"
"$TMP/stage-tests"
