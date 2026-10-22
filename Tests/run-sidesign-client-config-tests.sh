#!/usr/bin/env bash
set -euo pipefail
export PATH="/workspace/tooling/swift603/usr/bin:$PATH"
cd "$(dirname "$0")/.."
build=$(mktemp -d); trap 'rm -rf "$build"' EXIT
cat > "$build/SideSign.swift" <<'SWIFT'
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
public struct SideSignHeaders: Sendable, Equatable {
 public struct GrandSlam: Sendable, Equatable { public var service="default-service"; public var headerVersion="default-version"; public var authApp="default-app"; public var userAgent="default-gs-ua"; public init(service:String="default-service",headerVersion:String="default-version",authApp:String="default-app",userAgent:String="default-gs-ua"){self.service=service;self.headerVersion=headerVersion;self.authApp=authApp;self.userAgent=userAgent} }
 public struct AppleAuth: Sendable, Equatable { public var appIDKey="default-key"; public var userAgent="default-aa-ua"; public init(appIDKey:String="default-key",userAgent:String="default-aa-ua"){self.appIDKey=appIDKey;self.userAgent=userAgent} }
 public struct DeveloperServices: Sendable, Equatable { public var clientID="default-client"; public var protocolVersion="default-pv"; public var servicesProtocolVersion="default-spv"; public var userAgent="default-ds-ua"; public init(clientID:String="default-client",protocolVersion:String="default-pv",servicesProtocolVersion:String="default-spv",userAgent:String="default-ds-ua"){self.clientID=clientID;self.protocolVersion=protocolVersion;self.servicesProtocolVersion=servicesProtocolVersion;self.userAgent=userAgent} }
 public var grandSlam=GrandSlam(); public var appleAuth=AppleAuth(); public var developerServices=DeveloperServices()
 public init(grandSlam:GrandSlam=GrandSlam(),appleAuth:AppleAuth=AppleAuth(),developerServices:DeveloperServices=DeveloperServices()){self.grandSlam=grandSlam;self.appleAuth=appleAuth;self.developerServices=developerServices}
}
public final class DeveloperPortal: Sendable { public let customHeaders: SideSignHeaders; public init(session: URLSession = .shared, customHeaders: SideSignHeaders = SideSignHeaders()){self.customHeaders=customHeaders} }
SWIFT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -emit-module -emit-object -module-name SideSign "$build/SideSign.swift" -emit-module-path "$build/SideSign.swiftmodule" -o "$build/SideSign.o"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -I "$build" Sources/EiliStore/EiliSideSignClientConfiguration.swift Tests/EiliSideSignClientConfigurationTests.swift "$build/SideSign.o" -o "$build/test"
"$build/test"
