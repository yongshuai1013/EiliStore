import Foundation

public struct Team: Sendable, Equatable, Hashable { public var identifier: String; public init(_ id: String) { identifier = id } }
public struct AppID: Sendable, Equatable { public var identifier: String; public var name: String; public init(_ id: String, name: String? = nil) { identifier = id; self.name = name ?? id } }
public struct ListedProvisioningProfile: Sendable, Equatable { public var identifier: String?; public var name: String; public init(_ id: String? = nil, name: String? = nil) { identifier = id; self.name = name ?? id ?? "" } }
public struct X509Certificate: Sendable, Equatable { public var identifier: String; public var name: String; public var machineName: String?; public init(_ id: String = "cert", name: String? = nil, machineName: String? = nil) { identifier = id; self.name = name ?? id; self.machineName = machineName } }
public struct AppGroup: Sendable, Equatable { public var groupID: String; public var name: String; public init(_ id: String = "group", name: String? = nil) { groupID = id; self.name = name ?? id } }
public struct Device: Sendable, Equatable { public var identifier: String; public var name: String; public init(_ id: String = "device", name: String? = nil) { identifier = id; self.name = name ?? id } }
public struct ProvisioningProfile: Sendable { public init() {} }
public enum ProfileType: Sendable { case iOS }
public enum DeviceType: Sendable { case iOS }
