#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -x /workspace/tooling/swift603/usr/bin/swiftc ]]; then export PATH="/workspace/tooling/swift603/usr/bin:$PATH"; fi
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
build=$(mktemp -d); home=$(mktemp -d)
trap 'rm -rf "$build" "$home"' EXIT
swiftc -swift-version 5 -parse-as-library -emit-module -emit-object -module-name SideSign -emit-module-path "$build/SideSign.swiftmodule" Tests/Fixtures/PaxAuthSideSignStub.swift -o "$build/SideSign.o"
swiftc -swift-version 5 -parse-as-library -I "$build" Sources/EiliStore/TwoFACodeProvider.swift Sources/EiliStore/PaxAuthService.swift Tests/PaxAuthServiceFlowTests.swift "$build/SideSign.o" -o "$build/login-flow-tests"
HOME="$home" "$build/login-flow-tests"
