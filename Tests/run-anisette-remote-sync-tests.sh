#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/workspace/tooling/swift603/usr/bin:$PATH"
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
BIN="$(mktemp "${TMPDIR:-/tmp}/anisette-remote-sync-tests.XXXXXX")"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/EiliStore/EiliAnisetteClientConfiguration.swift" \
  "$ROOT/Sources/EiliStore/EiliAnisetteRemoteServerSync.swift" \
  "$ROOT/Tests/EiliAnisetteRemoteServerSyncTests.swift" \
  -o "$BIN"
"$BIN"
