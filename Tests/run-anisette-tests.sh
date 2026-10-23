#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/workspace/tooling/swift603/usr/bin:$PATH"
command -v swiftc >/dev/null || { echo 'swiftc not found' >&2; exit 2; }
build=$(mktemp -d); isolated_home=$(mktemp -d)
trap 'rm -rf "$build" "$isolated_home"' EXIT
swiftc -swift-version 6 -parse-as-library -emit-module -emit-object -module-name SideSign \
  -emit-module-path "$build/SideSign.swiftmodule" Tests/Fixtures/EiliAnisetteSideSignStub.swift -o "$build/SideSign.o"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -I "$build" \
  Sources/EiliStore/EiliLoginDiagnostics.swift \
  Sources/EiliStore/ADIElfMetadata.swift Sources/EiliStore/ADILibraryCompatibility.swift Tests/Fixtures/ADIElfFixture.swift \
  Tests/Fixtures/FakeADIRuntimeLibraryDownloader.swift \
  Sources/EiliStore/EiliAnisetteClientConfiguration.swift Sources/EiliStore/EiliAnisetteConfigurationAdapter.swift \
  Sources/EiliStore/EiliAnisetteService.swift Tests/EiliAnisetteServiceTests.swift Tests/Fixtures/ELFLibraryFixtures.swift "$build/SideSign.o" -o "$build/anisette-tests-remote"
HOME="$isolated_home" "$build/anisette-tests-remote"
swiftc -swift-version 6 -parse-as-library -emit-module -emit-object -module-name AnisetteKit \
  -emit-module-path "$build/AnisetteKit.swiftmodule" Tests/Fixtures/FakeAnisetteKit.swift -o "$build/AnisetteKit.o"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -D EILI_ON_DEVICE_ANISETTE -I "$build" \
  Sources/EiliStore/EiliLoginDiagnostics.swift \
  Sources/EiliStore/ADIElfMetadata.swift Sources/EiliStore/ADILibraryCompatibility.swift Tests/Fixtures/ADIElfFixture.swift \
  Tests/Fixtures/FakeADIRuntimeLibraryDownloader.swift \
  Sources/EiliStore/EiliAnisetteClientConfiguration.swift Sources/EiliStore/EiliAnisetteConfigurationAdapter.swift \
  Sources/EiliStore/EiliAnisetteService.swift Tests/EiliAnisetteServiceTests.swift Tests/Fixtures/ELFLibraryFixtures.swift \
  "$build/SideSign.o" "$build/AnisetteKit.o" -o "$build/anisette-tests-local"
HOME="$isolated_home" "$build/anisette-tests-local"
