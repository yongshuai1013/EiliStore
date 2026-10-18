import Foundation

public enum DeveloperPortalValidationError: Error, LocalizedError, Equatable {
    case emptyName
    case invalidName
    case invalidBundleIdentifier
    case invalidAppGroupIdentifier
    case missingProfileIdentifier
    case operationFailed
    case missingIdentifier
    case invalidDeviceIdentifier
    case invalidProfileConfiguration
    public var errorDescription: String? {
        switch self {
        case .emptyName: return "名稱不可為空。"
        case .invalidName: return "名稱不可包含控制字元。"
        case .invalidBundleIdentifier: return "Bundle ID 格式無效，請使用 com.example.app 格式。"
        case .invalidAppGroupIdentifier: return "App Group ID 格式無效，請使用 group.com.example 格式。"
        case .missingProfileIdentifier: return "找不到描述檔的 Portal 識別碼，請重新整理。"
        case .operationFailed: return "Apple 未確認刪除成功，請重新整理後檢查。"
        case .missingIdentifier: return "缺少必要的 Portal 識別碼，或識別碼含有空白。"
        case .invalidDeviceIdentifier: return "UDID 格式無效。支援 40 位十六進位、8-16 位格式及 Mac UUID。"
        case .invalidProfileConfiguration: return "請提供有效的描述檔類型、完整憑證 ID，以及該類型所需的裝置 ID。"
        }
    }
}

public enum DeveloperPortalValidation {
    public static func requireIdentifier(_ value: String?) throws {
        guard let value = value, !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw DeveloperPortalValidationError.missingIdentifier
        }
    }
    public static func validateName(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeveloperPortalValidationError.emptyName }
        guard value.rangeOfCharacter(from: .controlCharacters) == nil else { throw DeveloperPortalValidationError.invalidName }
    }
    public static func validateBundleIdentifier(_ value: String) throws {
        guard value.range(of: #"\A[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil else {
            throw DeveloperPortalValidationError.invalidBundleIdentifier
        }
    }
    public static func validateAppGroupIdentifier(_ value: String) throws {
        guard value.range(of: #"\Agroup\.[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil else {
            throw DeveloperPortalValidationError.invalidAppGroupIdentifier
        }
    }
    public static func validateDeviceIdentifier(_ value: String) throws {
        let pattern = #"\A(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})\z"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { throw DeveloperPortalValidationError.invalidDeviceIdentifier }
    }
}
