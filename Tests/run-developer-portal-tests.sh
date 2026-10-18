#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_BIN="${SWIFT_BIN:-$(command -v swiftc || true)}"
if [[ -z "$SWIFT_BIN" ]]; then echo "swiftc not found; set SWIFT_BIN to a Swift 6 compiler" >&2; exit 127; fi
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

# Preserve and run the pre-existing validation suite.
"$SWIFT_BIN" -swift-version 6 -strict-concurrency=complete Sources/EiliStore/DeveloperPortalValidation.swift Tests/DeveloperPortalValidationTests.swift -o "$build/portal-validation-tests"
"$build/portal-validation-tests"

# Build lightweight test-only modules. These do not validate an iOS build or SideSign wire behavior.
"$SWIFT_BIN" -swift-version 6 -parse-as-library -emit-module -emit-object -module-name Combine Tests/Fixtures/PortalCombineStub.swift -o "$build/Combine.o" -emit-module-path "$build/Combine.swiftmodule"
"$SWIFT_BIN" -swift-version 6 -parse-as-library -emit-module -emit-object -module-name SideSign Tests/Fixtures/PortalSideSignStub.swift -o "$build/SideSign.o" -emit-module-path "$build/SideSign.swiftmodule"
# Compile the production protocol declaration verbatim, not the network-backed production service implementation.
awk 'BEGIN{copy=0} /^public protocol DeveloperPortalServicing:/{copy=1; print "import SideSign"} copy{print} copy && /^}/{exit}' Sources/EiliStore/DeveloperPortalService.swift > "$build/DeveloperPortalServicing.swift"
cat > "$build/DefaultService.swift" <<'STUB'
import Foundation
import SideSign
public final class DeveloperPortalService: DeveloperPortalServicing, @unchecked Sendable {
 public static let shared = DeveloperPortalService(); private init() {}
 public func fetchTeams() async throws -> [SideSign.Team] { fatalError("test default service must not be used") }
 public func fetchAppIDs(for team: SideSign.Team) async throws -> [SideSign.AppID] { fatalError("test default service must not be used") }
 public func fetchProfiles(for team: SideSign.Team) async throws -> [SideSign.ListedProvisioningProfile] { fatalError("test default service must not be used") }
 public func fetchCertificates(for team: SideSign.Team) async throws -> [SideSign.X509Certificate] { fatalError("test default service must not be used") }
 public func fetchAppGroups(for team: SideSign.Team) async throws -> [SideSign.AppGroup] { fatalError("test default service must not be used") }
 public func fetchDevices(for team: SideSign.Team) async throws -> [SideSign.Device] { fatalError("test default service must not be used") }
}
public final class PaxAuthService: @unchecked Sendable { public static let shared = PaxAuthService(); public var hasSavedSession = false; private init() {} }
STUB
"$SWIFT_BIN" -swift-version 6 -strict-concurrency=complete -I "$build" \
  Sources/EiliStore/DeveloperPortalValidation.swift "$build/DeveloperPortalServicing.swift" "$build/DefaultService.swift" \
  Sources/EiliStore/DeveloperPortalModel.swift Tests/DeveloperPortalTestSupport.swift Tests/DeveloperPortalModelTests.swift \
  "$build/Combine.o" "$build/SideSign.o" \
  -o "$build/portal-model-tests"
"$build/portal-model-tests"
