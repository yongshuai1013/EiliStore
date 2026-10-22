#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_bin=/workspace/tooling/swift603/usr/bin
[[ ! -x "$swift_bin/swiftc" ]] || export PATH="$swift_bin:$PATH"
compiler="$(command -v swiftc || true)"
[[ -n "$compiler" ]] || { echo 'swiftc required' >&2; exit 127; }
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
mkdir -p "$build/modules" "$build/home/Documents" "$build/tmp"
export HOME="$build/home" TMPDIR="$build/tmp/"
export IPA_TEST_BUNDLE_ID="test.ipa-import-$(date +%s)-$$"
if [[ "$(uname -s)" == Darwin ]]; then extension=dylib; else extension=so; fi
cat > "$build/SwiftUI.swift" <<'EOF'
public protocol ObservableObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
EOF
cat > "$build/SideSign.swift" <<'EOF'
import Foundation
public struct Team { public init() {} }
public struct KeyStore { public init() {} }
public struct ProvisioningProfile {
    public let bundleIdentifier: String
    public let data = Data([7])
    public let expirationDate: Date? = nil
    public init(bundleIdentifier: String) { self.bundleIdentifier = bundleIdentifier }
}
public enum SignerTestState { public static var count = 0; public static var shouldFail = false }
public struct AppBundleSigner {
    public init(team: Team, keyStore: KeyStore) {}
    public func signApp(at: URL, provisioningProfiles: [ProvisioningProfile]) async throws {
        SignerTestState.count += 1
        if SignerTestState.shouldFail { throw NSError(domain: "fake-sign", code: 1) }
    }
}
EOF
cat > "$build/ZIPFoundation.swift" <<'EOF'
import Foundation
public enum CompressionLevel { case none }
extension FileManager {
    public func unzipItem(at: URL, to: URL) throws {
        let app = to.appendingPathComponent("Payload/Fixture.app", isDirectory: true)
        try createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": ProcessInfo.processInfo.environment["IPA_TEST_BUNDLE_ID"]!, "CFBundleName": "Fixture"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
    }
    public func zipAppBundle(at: URL, compressionLevel: CompressionLevel) throws -> URL {
        let result = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        try Data([8,9]).write(to: result)
        return result
    }
}
EOF
for module in SwiftUI SideSign ZIPFoundation; do
    "$compiler" -swift-version 5 -emit-module -emit-library -module-name "$module" "$build/$module.swift" \
        -emit-module-path "$build/modules/$module.swiftmodule" -o "$build/modules/lib$module.$extension"
done
"$compiler" -swift-version 5 -I "$build/modules" -L "$build/modules" -lSwiftUI -lSideSign -lZIPFoundation \
    "$repo_root/Tests/Fixtures/IPAInstallerMocks.swift" \
    "$repo_root/Sources/EiliStore/IPAImportStore.swift" \
    "$repo_root/Sources/EiliStore/SourceAppInstaller.swift" \
    "$repo_root/Tests/IPAInstallerOfflineTests.swift" -o "$build/ipa-installer-tests"
if [[ "$(uname -s)" == Darwin ]]; then
    DYLD_LIBRARY_PATH="$build/modules${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$build/ipa-installer-tests"
else
    LD_LIBRARY_PATH="$build/modules${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$build/ipa-installer-tests"
fi
