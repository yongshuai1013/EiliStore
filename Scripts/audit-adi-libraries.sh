#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/workspace/tooling/swift603/usr/bin:$PATH"
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
swiftc -swift-version 6 -parse-as-library Sources/EiliStore/ADIElfMetadata.swift \
  Sources/EiliStore/ADILibraryCompatibility.swift Scripts/audit-adi-libraries.swift -o "$build/audit-adi"
"$build/audit-adi" "$@"
