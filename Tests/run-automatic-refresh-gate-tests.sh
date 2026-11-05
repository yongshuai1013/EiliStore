#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-$(command -v swiftc || true)}"
if [[ ! -x "$SWIFTC" ]]; then
    echo "Swift compiler not found; automatic refresh gate tests were not run." >&2
    exit 2
fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
"$SWIFTC" -swift-version 6 -strict-concurrency=complete -parse-as-library \
    Sources/EiliStore/AutomaticRefreshGates.swift Tests/AutomaticRefreshGateTests.swift \
    -o "$build/automatic-refresh-gate-tests"
"$build/automatic-refresh-gate-tests"
