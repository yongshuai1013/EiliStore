#!/usr/bin/env bash
set -euo pipefail
export PATH="/workspace/tooling/swift603/usr/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
BIN="$(mktemp "${TMPDIR:-/tmp}/anisette-client-config-tests.XXXXXX")"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete "$ROOT/Sources/EiliStore/EiliAnisetteClientConfiguration.swift" "$ROOT/Tests/EiliAnisetteClientConfigurationTests.swift" -o "$BIN"
"$BIN"
