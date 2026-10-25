import Foundation
import SideSign

public struct EiliSideSignClientConfiguration: Sendable, Equatable {
    public struct GrandSlam: Sendable, Equatable { public var service = ""; public var headerVersion = ""; public var authApp = ""; public var userAgent = ""; public var clientInfo = ""; public var xcodeVersion = ""; public var phoneClientInfo = ""; public init(service: String = "", headerVersion: String = "", authApp: String = "", userAgent: String = "", clientInfo: String = "", xcodeVersion: String = "", phoneClientInfo: String = "") { self.service=service; self.headerVersion=headerVersion; self.authApp=authApp; self.userAgent=userAgent; self.clientInfo=clientInfo; self.xcodeVersion=xcodeVersion; self.phoneClientInfo=phoneClientInfo } }
    public struct AppleAuth: Sendable, Equatable { public var appIDKey = ""; public var userAgent = ""; public init(appIDKey: String = "", userAgent: String = "") { self.appIDKey=appIDKey; self.userAgent=userAgent } }
    public struct DeveloperServices: Sendable, Equatable { public var clientID = ""; public var protocolVersion = ""; public var servicesProtocolVersion = ""; public var userAgent = ""; public init(clientID: String = "", protocolVersion: String = "", servicesProtocolVersion: String = "", userAgent: String = "") { self.clientID=clientID; self.protocolVersion=protocolVersion; self.servicesProtocolVersion=servicesProtocolVersion; self.userAgent=userAgent } }
    public var grandSlam: GrandSlam; public var appleAuth: AppleAuth; public var developerServices: DeveloperServices
    public init(grandSlam: GrandSlam = .init(), appleAuth: AppleAuth = .init(), developerServices: DeveloperServices = .init()) { self.grandSlam=grandSlam; self.appleAuth=appleAuth; self.developerServices=developerServices }
    public static let empty = Self()
    public enum ConfigError: LocalizedError { case invalidJSON, invalidSchema, unknownField, invalidValue, tooLarge, storageFailure, unsafeFile
        public var errorDescription: String? { switch self { case .invalidJSON:return "JSON 格式無效。"; case .invalidSchema:return "JSON 結構或欄位型別無效。"; case .unknownField:return "包含不支援欄位。"; case .invalidValue:return "欄位值無效。"; case .tooLarge:return "設定超過允許大小。"; case .storageFailure:return "設定讀寫失敗。"; case .unsafeFile:return "設定檔案不安全或無法讀取。" } }
    }
    private static let names = [["service","headerVersion","authApp","userAgent","clientInfo","xcodeVersion","phoneClientInfo"],["appIDKey","userAgent"],["clientID","protocolVersion","servicesProtocolVersion","userAgent"]]
    private var values: [String] { [grandSlam.service,grandSlam.headerVersion,grandSlam.authApp,grandSlam.userAgent,grandSlam.clientInfo,grandSlam.xcodeVersion,grandSlam.phoneClientInfo,appleAuth.appIDKey,appleAuth.userAgent,developerServices.clientID,developerServices.protocolVersion,developerServices.servicesProtocolVersion,developerServices.userAgent] }
    public func validated() throws -> Self {
        var result=self; var v=values
        for i in v.indices { guard !v[i].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ConfigError.invalidValue }; v[i]=v[i].trimmingCharacters(in:.whitespacesAndNewlines); guard v[i].utf8.count <= 4096, v[i].unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) else { throw ConfigError.invalidValue } }
        for i in [1,2,7,9,10,11] where !v[i].isEmpty { guard v[i].unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { throw ConfigError.invalidValue } }
        result.grandSlam = .init(service:v[0],headerVersion:v[1],authApp:v[2],userAgent:v[3],clientInfo:v[4],xcodeVersion:v[5],phoneClientInfo:v[6]); result.appleAuth = .init(appIDKey:v[7],userAgent:v[8]); result.developerServices = .init(clientID:v[9],protocolVersion:v[10],servicesProtocolVersion:v[11],userAgent:v[12]); return result
    }
    public static func decodeJSON(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw ConfigError.tooLarge }
        let obj: Any; do { obj=try JSONSerialization.jsonObject(with:data) } catch { throw ConfigError.invalidJSON }
        guard let root=obj as? [String:Any] else { throw ConfigError.invalidSchema }
        let groups=["grandSlam","appleAuth","developerServices"]; guard Set(root.keys).isSubset(of:Set(groups)) else { throw ConfigError.unknownField }
        var dataGroups=[[String:String]](repeating:[:],count:3)
        for (i,g) in groups.enumerated() { guard let group=root[g] else { continue }; guard let dict=group as? [String:Any] else { throw ConfigError.invalidSchema }; let allowed=Set(names[i]); guard Set(dict.keys).isSubset(of:allowed) else { throw ConfigError.unknownField }; for (k,x) in dict { guard let s=x as? String else { throw ConfigError.invalidSchema }; dataGroups[i][k]=s } }
        return try Self(grandSlam:.init(service:dataGroups[0]["service"] ?? "",headerVersion:dataGroups[0]["headerVersion"] ?? "",authApp:dataGroups[0]["authApp"] ?? "",userAgent:dataGroups[0]["userAgent"] ?? "",clientInfo:dataGroups[0]["clientInfo"] ?? "",xcodeVersion:dataGroups[0]["xcodeVersion"] ?? "",phoneClientInfo:dataGroups[0]["phoneClientInfo"] ?? ""),appleAuth:.init(appIDKey:dataGroups[1]["appIDKey"] ?? "",userAgent:dataGroups[1]["userAgent"] ?? ""),developerServices:.init(clientID:dataGroups[2]["clientID"] ?? "",protocolVersion:dataGroups[2]["protocolVersion"] ?? "",servicesProtocolVersion:dataGroups[2]["servicesProtocolVersion"] ?? "",userAgent:dataGroups[2]["userAgent"] ?? "")).validated()
    }
    public func encodedJSON() throws -> Data { let x=try validated(); let object:[String:Any] = ["grandSlam":["service":x.grandSlam.service,"headerVersion":x.grandSlam.headerVersion,"authApp":x.grandSlam.authApp,"userAgent":x.grandSlam.userAgent,"clientInfo":x.grandSlam.clientInfo,"xcodeVersion":x.grandSlam.xcodeVersion,"phoneClientInfo":x.grandSlam.phoneClientInfo],"appleAuth":["appIDKey":x.appleAuth.appIDKey,"userAgent":x.appleAuth.userAgent],"developerServices":["clientID":x.developerServices.clientID,"protocolVersion":x.developerServices.protocolVersion,"servicesProtocolVersion":x.developerServices.servicesProtocolVersion,"userAgent":x.developerServices.userAgent]]; let d=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]); guard d.count <= 65_536 else { throw ConfigError.tooLarge }; return d }
    public func resolvedHeaders() throws -> SideSignHeaders { let x=try validated(), defaults=SideSignHeaders(); return .init(grandSlam:.init(service:x.grandSlam.service.isEmpty ? defaults.grandSlam.service:x.grandSlam.service,headerVersion:x.grandSlam.headerVersion.isEmpty ? defaults.grandSlam.headerVersion:x.grandSlam.headerVersion,authApp:x.grandSlam.authApp.isEmpty ? defaults.grandSlam.authApp:x.grandSlam.authApp,userAgent:x.grandSlam.userAgent.isEmpty ? defaults.grandSlam.userAgent:x.grandSlam.userAgent,clientInfo:x.grandSlam.clientInfo.isEmpty ? defaults.grandSlam.clientInfo:x.grandSlam.clientInfo,xcodeVersion:x.grandSlam.xcodeVersion.isEmpty ? defaults.grandSlam.xcodeVersion:x.grandSlam.xcodeVersion,phoneClientInfo:x.grandSlam.phoneClientInfo.isEmpty ? defaults.grandSlam.phoneClientInfo:x.grandSlam.phoneClientInfo),appleAuth:.init(appIDKey:x.appleAuth.appIDKey.isEmpty ? defaults.appleAuth.appIDKey:x.appleAuth.appIDKey,userAgent:x.appleAuth.userAgent.isEmpty ? defaults.appleAuth.userAgent:x.appleAuth.userAgent),developerServices:.init(clientID:x.developerServices.clientID.isEmpty ? defaults.developerServices.clientID:x.developerServices.clientID,protocolVersion:x.developerServices.protocolVersion.isEmpty ? defaults.developerServices.protocolVersion:x.developerServices.protocolVersion,servicesProtocolVersion:x.developerServices.servicesProtocolVersion.isEmpty ? defaults.developerServices.servicesProtocolVersion:x.developerServices.servicesProtocolVersion,userAgent:x.developerServices.userAgent.isEmpty ? defaults.developerServices.userAgent:x.developerServices.userAgent)) }
}

public actor EiliSideSignClientConfigurationStore {
    public static let shared=EiliSideSignClientConfigurationStore(); private let fileURL:URL
    public init(fileURL:URL?=nil) { if let fileURL { self.fileURL=fileURL } else { let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Library/Application Support"); self.fileURL=base.appendingPathComponent("EiliStore/ClientConfiguration/sidesign-overrides.json") } }
    public func load() throws -> EiliSideSignClientConfiguration { let fm=FileManager.default; guard fm.fileExists(atPath:fileURL.path) else { return .empty }; do { let a=try fm.attributesOfItem(atPath:fileURL.path); guard a[.type] as? FileAttributeType == .typeRegular, let size=a[.size] as? NSNumber, size.intValue <= 65_536, (try fileURL.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw EiliSideSignClientConfiguration.ConfigError.unsafeFile }; let handle = try FileHandle(forReadingFrom:fileURL); defer { try? handle.close() }; let data = try handle.read(upToCount:65_537) ?? Data(); guard data.count <= 65_536 else { throw EiliSideSignClientConfiguration.ConfigError.tooLarge }; return try EiliSideSignClientConfiguration.decodeJSON(data) } catch let e as EiliSideSignClientConfiguration.ConfigError { throw e } catch { throw EiliSideSignClientConfiguration.ConfigError.storageFailure } }
    public func save(_ config: EiliSideSignClientConfiguration) throws {
        let data = try config.encodedJSON()
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #endif
            #if os(iOS) || os(tvOS) || os(watchOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            #endif
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            var mutableURL = fileURL; try? mutableURL.setResourceValues(resource)
        } catch { throw EiliSideSignClientConfiguration.ConfigError.storageFailure }
    }
    public func reset() throws { do { if FileManager.default.fileExists(atPath:fileURL.path) { try FileManager.default.removeItem(at:fileURL) } } catch { throw EiliSideSignClientConfiguration.ConfigError.storageFailure } }
    public func makePortal() throws -> SideSign.DeveloperPortal { SideSign.DeveloperPortal(customHeaders:try load().resolvedHeaders()) }
    /// Headers for a GSA login: identity fields the user has not
    /// explicitly overridden follow the anisette identity that will
    /// actually be presented, so the declared client matches the ADI
    /// that minted the anisette data. The Xcode version follows the
    /// value isideload's working login sends.
    public func resolvedLoginHeaders(anisetteClientInfo: String, anisetteUserAgent: String) throws -> SideSignHeaders { let config = try load(); var headers = try config.resolvedHeaders(); if config.grandSlam.clientInfo.isEmpty, !anisetteClientInfo.isEmpty { headers.grandSlam.clientInfo = anisetteClientInfo }; if config.grandSlam.userAgent.isEmpty, !anisetteUserAgent.isEmpty { headers.grandSlam.userAgent = anisetteUserAgent }; if config.grandSlam.xcodeVersion.isEmpty { headers.grandSlam.xcodeVersion = "27.0 (27A5218g)" }; return headers }
}
