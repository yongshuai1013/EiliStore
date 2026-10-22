#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_bin="/workspace/tooling/swift603/usr/bin"
if [[ -x "$swift_bin/swiftc" ]]; then
  export PATH="$swift_bin:$PATH"
fi
compiler="$(command -v swiftc || true)"
if [[ -z "$compiler" ]]; then
  echo "error: swiftc not found (checked /workspace/tooling/swift603/usr/bin and system PATH)" >&2
  exit 127
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
"$compiler" "$repo_root/Sources/EiliStore/IPAImportStore.swift" "$repo_root/Tests/IPAImportStoreTests.swift" -o "$build_dir/ipa-import-tests"
"$build_dir/ipa-import-tests"
"$compiler" "$repo_root/Sources/EiliStore/IPAInstallMetadata.swift" "$repo_root/Tests/IPAInstallMetadataTests.swift" -o "$build_dir/ipa-metadata-tests"
"$build_dir/ipa-metadata-tests"
