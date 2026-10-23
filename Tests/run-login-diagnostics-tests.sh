#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -x /workspace/tooling/swift603/usr/bin/swiftc ]]; then export PATH="/workspace/tooling/swift603/usr/bin:$PATH"; fi
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Sources/EiliStore/EiliLoginDiagnostics.swift Tests/EiliLoginDiagnosticsTests.swift -o "$build/diagnostics-tests"
set +e
"$build/diagnostics-tests" interrupt "$build/login.json"
status=$?
set -e
[[ "$status" == 86 ]] || { echo "Expected abrupt-exit status 86, got $status" >&2; exit 1; }
"$build/diagnostics-tests" verify "$build/login.json"
