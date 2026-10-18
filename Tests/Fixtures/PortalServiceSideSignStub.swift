import Foundation
public struct DeviceType: OptionSet, Sendable, Equatable { public let rawValue:Int; public init(rawValue:Int){self.rawValue=rawValue}; public static let none=DeviceType([]), iPhone=DeviceType(rawValue:1), iPad=DeviceType(rawValue:2), appleTV=DeviceType(rawValue:4), appleWatch=DeviceType(rawValue:8), mac=DeviceType(rawValue:16), visionPro=DeviceType(rawValue:32), all=DeviceType(rawValue:63) }
//
//  ProfileType.swift
//  SideSign
//
//  Created by Magesh K on 11/09/26.
//  Copyright © 2026 SideSign. All rights reserved.
//

import Foundation

public struct ProfileType: RawRepresentable, Sendable, Codable, Equatable, Hashable, CustomStringConvertible, CaseIterable {
    public let rawValue: String

    public enum Category: String, Sendable, Codable {
        case development
        case distribution
    }

    public typealias ManagementStyle = ProfileManagementStyle

    // Development (Free & Paid)
    public static let iOS              = ProfileType(rawValue: "ios")
    public static let tvOS             = ProfileType(rawValue: "tvos")
    public static let macOS            = ProfileType(rawValue: "mac")
    public static let visionOS         = ProfileType(rawValue: "visionos")
    // Development (Paid Only)
    public static let driverKit        = ProfileType(rawValue: "driverkit")

    // Distribution (Paid Only)
    public static let adHoc            = ProfileType(rawValue: "adhoc")
    public static let tvOSAdHoc        = ProfileType(rawValue: "tvos-adhoc")
    public static let appStore         = ProfileType(rawValue: "appstore")
    public static let tvOSAppStore     = ProfileType(rawValue: "tvos-appstore")
    public static let macAppStore      = ProfileType(rawValue: "mac-appstore")
    public static let developerID      = ProfileType(rawValue: "developer-id")

    public static let allCases: [ProfileType] = [
        .iOS, .tvOS, .macOS, .visionOS, .driverKit,
        .adHoc, .tvOSAdHoc, .appStore, .tvOSAppStore, .macAppStore, .developerID
    ]

    // Profiles supported by Free accounts
    public static var freeAccountCases: [ProfileType] {
        allCases.filter { $0.isFreeAccountSupported }
    }

    // Profiles supported exclusively by Paid accounts
    public static var paidOnlyCases: [ProfileType] {
        allCases.filter { $0.isPaidOnly }
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init?(argument: String) {
        switch argument.lowercased() {
        case "ios", "ios development":
            self = .iOS
        case "tvos", "tvos development":
            self = .tvOS
        case "mac", "macos", "mac app development", "macos development":
            self = .macOS
        case "visionos", "visionos development":
            self = .visionOS
        case "driverkit", "driverkit development":
            self = .driverKit
        case "adhoc":
            self = .adHoc
        case "tvos-adhoc":
            self = .tvOSAdHoc
        case "appstore", "store":
            self = .appStore
        case "tvos-appstore":
            self = .tvOSAppStore
        case "mac-appstore":
            self = .macAppStore
        case "developer-id", "developerid":
            self = .developerID
        default:
            return nil
        }
    }

    public var isFreeAccountSupported: Bool {
        switch self {
        case .iOS, .tvOS, .macOS, .visionOS:
            return true
        default:
            return false
        }
    }

    public var isPaidOnly: Bool {
        !isFreeAccountSupported
    }

    public var category: Category {
        switch self {
        case .iOS, .tvOS, .macOS, .visionOS, .driverKit:
            return .development
        case .adHoc, .tvOSAdHoc, .appStore, .tvOSAppStore, .macAppStore, .developerID:
            return .distribution
        default:
            return .development
        }
    }

    public var displayName: String {
        switch self {
        case .iOS:          return "iOS App Development (ios)"
        case .tvOS:         return "tvOS App Development (tvos)"
        case .macOS:        return "macOS App Development (mac)"
        case .visionOS:     return "visionOS App Development (visionos)"
        case .driverKit:    return "DriverKit App Development (driverkit)"
        case .adHoc:        return "Ad Hoc (adhoc)"
        case .tvOSAdHoc:    return "tvOS Ad Hoc (tvos-adhoc)"
        case .appStore:     return "App Store Connect (appstore)"
        case .tvOSAppStore: return "tvOS App Store Connect (tvos-appstore)"
        case .macAppStore:  return "Mac App Store Connect (mac-appstore)"
        case .developerID:  return "Developer ID (developer-id)"
        default:            return rawValue
        }
    }

    public var acceptedDeviceTypes: DeviceType {
        switch self {
        case .iOS, .adHoc:
            return [.iPhone, .iPad]
        case .tvOS, .tvOSAdHoc:
            return [.appleTV]
        case .macOS, .driverKit:
            return [.mac]
        case .visionOS:
            return [.visionPro]
        case .appStore, .tvOSAppStore, .macAppStore, .developerID:
            return .none
        default:
            return .none
        }
    }

    public var primaryDeviceType: DeviceType {
        switch self {
        case .iOS, .adHoc, .appStore:
            return .iPhone
        case .tvOS, .tvOSAdHoc, .tvOSAppStore:
            return .appleTV
        case .macOS, .macAppStore, .developerID, .driverKit:
            return .mac
        case .visionOS:
            return .visionPro
        default:
            return .iPhone
        }
    }

    public var subPlatformParameter: String? {
        switch self {
        case .iOS, .adHoc, .appStore:
            return nil
        case .tvOS, .tvOSAdHoc, .tvOSAppStore:
            return "tvOS"
        case .macOS, .macAppStore, .developerID, .driverKit:
            return "macOS"
        case .visionOS:
            return "visionOS"
        default:
            return nil
        }
    }

    public var distributionTypeParameter: String {
        switch self {
        case .iOS, .tvOS, .macOS, .visionOS, .driverKit:
            return "limited"
        case .adHoc, .tvOSAdHoc:
            return "adhoc"
        case .appStore, .tvOSAppStore, .macAppStore:
            return "store"
        case .developerID:
            return "developer-id"
        default:
            return "limited"
        }
    }

    public var description: String { displayName }
}

public enum ProfileManagementStyle: String, Sendable, Codable, CaseIterable {
    case manual
    case xcodeManaged

    public init?(argument: String) {
        switch argument.lowercased() {
        case "manual":
            self = .manual
        case "xcode", "xcodemanaged", "xcode-managed":
            self = .xcodeManaged
        default:
            return nil
        }
    }
}
public struct Team: Sendable { public var identifier:String; public var type:Kind; public enum Kind:Sendable { case free, paid }; public init(_ id:String="team", type:Kind = .paid){identifier=id;self.type=type} }
public struct Feature: Hashable, Sendable, ExpressibleByStringLiteral { public let rawValue:String; public init(stringLiteral value:String){rawValue=value}; public static let appGroups:Feature="APG3427HIY" }
public struct AppID: Sendable { public var identifier:String; public var name:String; public var features:[Feature:String]=[:]; public init(_ id:String="com.example.app"){identifier=id;name=id}; public func copy()->AppID{self} }
public struct ListedProvisioningProfile:Sendable { public var identifier:String?; public init(_ id:String?=nil){identifier=id} }
public struct ProvisioningProfile:Sendable { public init(){} }
public struct X509Certificate:Sendable { public init(){} }
public struct AppGroup:Sendable { public var groupID:String; public var name:String; public init(_ id:String="group.com.example.test"){groupID=id;name=id} }
public struct Device:Sendable { public var identifier:String; public var name:String; public init(_ id:String="12345678-1234-1234-1234-123456789012"){identifier=id;name=id} }
public struct Account:Sendable { public init(){} }
public struct Session:Sendable { public init(){} }
public protocol DeveloperPortalAPI:Sendable {
 func fetchTeams(for:Account,session:Session) async throws->[Team]
 func fetchAppIDs(for:Team,session:Session) async throws->[AppID]
 func listProvisioningProfiles(for:Team,session:Session) async throws->[ListedProvisioningProfile]
 func fetchCertificates(for:Team,session:Session) async throws->[X509Certificate]
 func fetchAppGroups(for:Team,session:Session) async throws->[AppGroup]
 func fetchDevices(for:Team,types:DeviceType,session:Session) async throws->[Device]
 func createProvisioningProfile(name:String,appID:AppID,certificateIDs:[String],deviceIDs:[String],type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile
 func updateProvisioningProfile(profileID:String,name:String,appIDId:String,certificateIDs:[String],deviceIDs:[String],type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile
 func downloadProvisioningProfile(profileID:String,team:Team,session:Session) async throws->ProvisioningProfile
 func downloadProvisioningProfile(for:AppID,isTeamProfile:Bool,subPlatform:String?,deviceType:DeviceType,team:Team,session:Session) async throws->ProvisioningProfile
 func downloadProvisioningProfile(for:AppID,isTeamProfile:Bool,type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile
 func downloadProvisioningProfile(for:AppID,type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile
 func deleteProvisioningProfile(profileID:String,team:Team,session:Session) async throws->Bool
 func addAppGroup(name:String,groupIdentifier:String,team:Team,session:Session) async throws->AppGroup
 func updateAppGroup(_ appGroup:AppGroup,team:Team,session:Session) async throws->AppGroup
 func deleteAppGroup(_ appGroup:AppGroup,team:Team,session:Session) async throws->Bool
 func updateAppID(_ appID:AppID,team:Team,session:Session) async throws->AppID
 func assignAppGroups(_ appGroups:[AppGroup],to appID:AppID,team:Team,session:Session) async throws->AppID
 func registerDevice(name:String,identifier:String,type:DeviceType,team:Team,session:Session) async throws->Device
 func updateDevice(_ device:Device,team:Team,session:Session) async throws->Device
 func disableDevice(_ device:Device,team:Team,session:Session) async throws->Device
 func deleteDevice(_ device:Device,team:Team,session:Session) async throws->Bool
}
public final class DeveloperPortal:DeveloperPortalAPI,@unchecked Sendable {
 public static let shared=DeveloperPortal(); private init(){}
 public func fetchTeams(for:Account,session:Session) async throws->[Team]{throw StubError.unconfigured}
 public func fetchAppIDs(for:Team,session:Session) async throws->[AppID]{throw StubError.unconfigured}
 public func listProvisioningProfiles(for:Team,session:Session) async throws->[ListedProvisioningProfile]{throw StubError.unconfigured}
 public func fetchCertificates(for:Team,session:Session) async throws->[X509Certificate]{throw StubError.unconfigured}
 public func fetchAppGroups(for:Team,session:Session) async throws->[AppGroup]{throw StubError.unconfigured}
 public func fetchDevices(for:Team,types:DeviceType,session:Session) async throws->[Device]{throw StubError.unconfigured}
 public func createProvisioningProfile(name:String,appID:AppID,certificateIDs:[String],deviceIDs:[String],type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile{throw StubError.unconfigured}
 public func updateProvisioningProfile(profileID:String,name:String,appIDId:String,certificateIDs:[String],deviceIDs:[String],type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile{throw StubError.unconfigured}
 public func downloadProvisioningProfile(profileID:String,team:Team,session:Session) async throws->ProvisioningProfile{throw StubError.unconfigured}
 public func downloadProvisioningProfile(for:AppID,isTeamProfile:Bool,subPlatform:String?,deviceType:DeviceType,team:Team,session:Session) async throws->ProvisioningProfile{throw StubError.unconfigured}
 public func downloadProvisioningProfile(for appID:AppID,isTeamProfile:Bool,type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile{try await downloadProvisioningProfile(for:appID,isTeamProfile:isTeamProfile,subPlatform:type.subPlatformParameter,deviceType:type.primaryDeviceType,team:team,session:session)}
 public func downloadProvisioningProfile(for appID:AppID,type:ProfileType,team:Team,session:Session) async throws->ProvisioningProfile{try await downloadProvisioningProfile(for:appID,isTeamProfile:true,type:type,team:team,session:session)}
 public func deleteProvisioningProfile(profileID:String,team:Team,session:Session) async throws->Bool{throw StubError.unconfigured}
 public func addAppGroup(name:String,groupIdentifier:String,team:Team,session:Session) async throws->AppGroup{throw StubError.unconfigured}
 public func updateAppGroup(_ appGroup:AppGroup,team:Team,session:Session) async throws->AppGroup{throw StubError.unconfigured}
 public func deleteAppGroup(_ appGroup:AppGroup,team:Team,session:Session) async throws->Bool{throw StubError.unconfigured}
 public func updateAppID(_ appID:AppID,team:Team,session:Session) async throws->AppID{throw StubError.unconfigured}
 public func assignAppGroups(_ appGroups:[AppGroup],to appID:AppID,team:Team,session:Session) async throws->AppID{throw StubError.unconfigured}
 public func registerDevice(name:String,identifier:String,type:DeviceType,team:Team,session:Session) async throws->Device{throw StubError.unconfigured}
 public func updateDevice(_ device:Device,team:Team,session:Session) async throws->Device{throw StubError.unconfigured}
 public func disableDevice(_ device:Device,team:Team,session:Session) async throws->Device{throw StubError.unconfigured}
 public func deleteDevice(_ device:Device,team:Team,session:Session) async throws->Bool{throw StubError.unconfigured}
}
public enum StubError:Error {case unconfigured}
