import Foundation
import SideSign

/// Apple Portal 記錄快取，不包含已安裝／外部 App 的 provisioning profile 到期日。
struct AppIDSnapshot: Codable {
    struct Record: Codable {
        let identifier: String
        let name: String
        let bundleIdentifier: String
        let expirationDate: Date?
        let features: [String: String]
        let entitlements: [String: String]

        init(_ appID: SideSign.AppID) {
            identifier = appID.identifier
            name = appID.name
            bundleIdentifier = appID.bundleIdentifier
            expirationDate = appID.expirationDate
            // SideSign 的 AppID.encode 不保存 features，故使用獨立的快取格式。
            features = Dictionary(uniqueKeysWithValues: appID.features.map { ($0.key.rawValue, $0.value) })
            entitlements = appID.entitlements
        }

        var appID: SideSign.AppID {
            SideSign.AppID(
                identifier: identifier,
                name: name,
                bundleIdentifier: bundleIdentifier,
                expirationDate: expirationDate,
                features: Dictionary(uniqueKeysWithValues: features.map { (SideSign.Feature(rawValue: $0.key), $0.value) }),
                entitlements: entitlements
            )
        }
    }

    let accountIdentifier: String
    let teamIdentifier: String
    let syncedAt: Date
    let records: [Record]

    /// 以成功取得的完整清單取代該 scope 的本地記錄，即新增、更新及移除 stale 記錄。
    /// 空的成功清單會清空本地 App ID 記錄；不完整／重複的清單則拒絕套用。
    init(appIDs: [SideSign.AppID], accountIdentifier: String, teamIdentifier: String, syncedAt: Date = Date()) throws {
        var identifiers = Set<String>()
        for appID in appIDs {
            guard !appID.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !appID.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identifiers.insert(appID.identifier).inserted else {
                throw AppIDSyncError.invalidRecords
            }
        }
        self.accountIdentifier = accountIdentifier
        self.teamIdentifier = teamIdentifier
        self.syncedAt = syncedAt
        self.records = appIDs.map(Record.init)
    }

    var appIDs: [SideSign.AppID] { records.map(\.appID) }
}

enum AppIDSyncError: LocalizedError {
    case invalidRecords
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .invalidRecords:
            return "App ID 清單包含無效或重複記錄，已保留上次同步資料。"
        case .accountChanged:
            return "登入帳戶已改變，未套用舊帳戶的 App ID 清單。"
        }
    }
}
