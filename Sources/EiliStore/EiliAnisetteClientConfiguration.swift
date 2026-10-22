import Foundation

public struct EiliAnisetteClientConfiguration: Equatable, Sendable, Codable {
    public var clientInfo: String
    public var userAgent: String
    public var customDeviceID: String
    public var customLocalUserID: String
    public var customSerialNumber: String
    public var customRoutingInfo: String
    public var customLocale: String
    public var customTimeZone: String
    public var customXcodeVersion: String

    public init(clientInfo: String = "", userAgent: String = "", customDeviceID: String = "", customLocalUserID: String = "", customSerialNumber: String = "", customRoutingInfo: String = "", customLocale: String = "", customTimeZone: String = "", customXcodeVersion: String = "") {
        self.clientInfo = clientInfo; self.userAgent = userAgent; self.customDeviceID = customDeviceID
        self.customLocalUserID = customLocalUserID; self.customSerialNumber = customSerialNumber
        self.customRoutingInfo = customRoutingInfo; self.customLocale = customLocale
        self.customTimeZone = customTimeZone; self.customXcodeVersion = customXcodeVersion
    }

    public static let empty = Self()

    public enum ConfigError: LocalizedError {
        case invalidJSON, invalidSchema, unknownField, conflictingAliases, invalidValue
        case tooLarge, storageFailure, unsafeFile
        public var errorDescription: String? {
            switch self {
            case .invalidJSON: return "設定 JSON 格式無效。"
            case .invalidSchema: return "設定 JSON 結構無效。"
            case .unknownField: return "設定包含不支援的欄位。"
            case .conflictingAliases: return "設定欄位別名內容衝突。"
            case .invalidValue: return "設定值無效。"
            case .tooLarge: return "設定內容超過允許大小。"
            case .storageFailure: return "設定讀寫失敗。"
            case .unsafeFile: return "設定檔案不安全或無法讀取。"
            }
        }
    }

    private static let fieldNames = ["clientInfo", "userAgent", "customDeviceID", "customLocalUserID", "customSerialNumber", "customRoutingInfo", "customLocale", "customTimeZone", "customXcodeVersion"]
    private static let aliases: [[String]] = [
        ["clientInfo", "client_info", "X-Mme-Client-Info"],
        ["userAgent", "user_agent", "User-Agent"],
        ["customDeviceID", "custom_device_id", "deviceID", "device_id", "deviceUniqueIdentifier", "X-Mme-Device-Id"],
        ["customLocalUserID", "custom_local_user_id", "localUserID", "local_user_id", "X-Apple-I-MD-LU"],
        ["customSerialNumber", "custom_serial_number", "serialNumber", "serial_number", "X-Apple-I-SRL-NO"],
        ["customRoutingInfo", "custom_routing_info", "routingInfo", "routing_info", "X-Apple-I-MD-RINFO"],
        ["customLocale", "custom_locale", "locale", "X-Apple-Locale"],
        ["customTimeZone", "custom_time_zone", "timeZone", "time_zone", "X-Apple-I-TimeZone"],
        ["customXcodeVersion", "custom_xcode_version", "xcodeVersion", "xcode_version", "X-Xcode-Version"]
    ]

    public func validated() throws -> Self {
        var result = self
        let values = [clientInfo, userAgent, customDeviceID, customLocalUserID, customSerialNumber, customRoutingInfo, customLocale, customTimeZone, customXcodeVersion]
        var cleaned: [String] = []
        for (index, value) in values.enumerated() {
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ConfigError.invalidValue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf8.count <= (index == 8 ? 128 : 4096) else { throw ConfigError.invalidValue }
            guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e }) else { throw ConfigError.invalidValue }
            cleaned.append(trimmed)
        }
        if !cleaned[2].isEmpty {
            guard UUID(uuidString: cleaned[2]) != nil else { throw ConfigError.invalidValue }
        }
        if !cleaned[5].isEmpty {
            guard cleaned[5].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), UInt64(cleaned[5]) != nil else { throw ConfigError.invalidValue }
        }
        if !cleaned[7].isEmpty { guard TimeZone(identifier: cleaned[7]) != nil else { throw ConfigError.invalidValue } }
        result.clientInfo = cleaned[0]; result.userAgent = cleaned[1]; result.customDeviceID = cleaned[2]
        result.customLocalUserID = cleaned[3]; result.customSerialNumber = cleaned[4]; result.customRoutingInfo = cleaned[5]
        result.customLocale = cleaned[6]; result.customTimeZone = cleaned[7]; result.customXcodeVersion = cleaned[8]
        return result
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw ConfigError.tooLarge }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ConfigError.invalidJSON }
        guard let dictionary = object as? [String: Any] else { throw ConfigError.invalidSchema }
        var values = Array(repeating: "", count: 9)
        var seen = Array(repeating: false, count: 9)
        for (key, value) in dictionary {
            guard let index = aliases.firstIndex(where: { $0.contains(key) }) else { throw ConfigError.unknownField }
            guard let string = value as? String else { throw ConfigError.invalidSchema }
            if seen[index] && values[index] != string { throw ConfigError.conflictingAliases }
            values[index] = string; seen[index] = true
        }
        return try Self(clientInfo: values[0], userAgent: values[1], customDeviceID: values[2], customLocalUserID: values[3], customSerialNumber: values[4], customRoutingInfo: values[5], customLocale: values[6], customTimeZone: values[7], customXcodeVersion: values[8]).validated()
    }

    public func encodedJSON() throws -> Data {
        let valid = try validated()
        let object: [String: String] = ["clientInfo": valid.clientInfo, "userAgent": valid.userAgent, "customDeviceID": valid.customDeviceID, "customLocalUserID": valid.customLocalUserID, "customSerialNumber": valid.customSerialNumber, "customRoutingInfo": valid.customRoutingInfo, "customLocale": valid.customLocale, "customTimeZone": valid.customTimeZone, "customXcodeVersion": valid.customXcodeVersion]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 65_536 else { throw ConfigError.tooLarge }
        return data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var fields: [String: String] = [:]
        for key in container.allKeys { fields[key.stringValue] = try container.decode(String.self, forKey: key) }
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: fields) }
        catch { throw ConfigError.invalidSchema }
        self = try Self.decodeJSON(data)
    }

    public func encode(to encoder: Encoder) throws {
        let value = try validated()
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, text) in zip(Self.fieldNames, [value.clientInfo, value.userAgent, value.customDeviceID, value.customLocalUserID, value.customSerialNumber, value.customRoutingInfo, value.customLocale, value.customTimeZone, value.customXcodeVersion]) {
            try container.encode(text, forKey: DynamicKey(stringValue: key)!)
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

public actor EiliAnisetteClientConfigurationStore {
    public static let shared = EiliAnisetteClientConfigurationStore()
    private let fileURL: URL
    public init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("EiliStore/ClientConfiguration/overrides.json")
        }
    }

    public func load() throws -> EiliAnisetteClientConfiguration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, size.intValue <= 65_536 else { throw EiliAnisetteClientConfiguration.ConfigError.unsafeFile }
            #if !os(Windows)
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw EiliAnisetteClientConfiguration.ConfigError.unsafeFile }
            #endif
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw EiliAnisetteClientConfiguration.ConfigError.tooLarge }
            return try EiliAnisetteClientConfiguration.decodeJSON(data)
        } catch let error as EiliAnisetteClientConfiguration.ConfigError { throw error }
        catch { throw EiliAnisetteClientConfiguration.ConfigError.storageFailure }
    }

    public func save(_ config: EiliAnisetteClientConfiguration) throws {
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
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutableURL = fileURL
            try? mutableURL.setResourceValues(values)
        } catch { throw EiliAnisetteClientConfiguration.ConfigError.storageFailure }
    }

    public func reset() throws {
        do { if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) } }
        catch { throw EiliAnisetteClientConfiguration.ConfigError.storageFailure }
    }
}
