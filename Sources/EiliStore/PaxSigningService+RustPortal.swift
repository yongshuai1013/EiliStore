import Foundation
import SideSign

// MARK: - Rust Portal（B 路線階段二）
//
// session 是 Rust 登入領出來的時候，PaxSigningService 的 Portal 操作
// 改走 isideload 的 dev API（EiliRustAuthService.devOp），結果在這裡
// 映射回 SideSign 的模型型別，讓上層流程（簽名／刷新）不感知差異。
// 證書私鑰仍走 SideSign 的纯本地 CertificateRequest（產生金鑰＋CSR
// 不聯網），只有「把 CSR 送給 Apple」這步換成 Rust。
extension PaxSigningService {
    var isRustSession: Bool { EiliLoginMethod.savedSessionOrigin == .rust }

    /// 以 session 保存的 token＋adsid 跑一個 Rust dev 操作。anisette 用
    /// 呼叫方剛以 sessionWithFreshAnisette 換上的新鮮快照。
    func rustDevOp(_ op: String, params: [String: Any], session: SideSign.Session) async throws -> [String: Any] {
        let anisette = session.anisetteData
        return try await EiliRustAuthService.shared.devOp(
            op, params: params,
            token: session.authToken, adsid: session.dsid,
            fetchAnisette: { _ in anisette }
        )
    }

    // MARK: - JSON -> SideSign 模型

    func rustMapCertificate(_ dict: [String: Any]) -> SideSign.X509Certificate? {
        guard let b64 = dict["cert_content_b64"] as? String, !b64.isEmpty,
              let der = Data(base64Encoded: b64) else { return nil }
        return SideSign.X509Certificate(
            data: der,
            identifier: (dict["certificate_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            machineName: (dict["machine_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            machineIdentifier: (dict["machine_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            status: (dict["status"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func rustMapDevice(_ dict: [String: Any]) -> SideSign.Device {
        SideSign.Device(
            name: dict["name"] as? String ?? "",
            identifier: dict["device_number"] as? String ?? "",
            type: .iPhone,
            deviceID: (dict["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            status: (dict["status"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func rustMapAppID(_ dict: [String: Any]) -> SideSign.AppID {
        var features: [SideSign.Feature: String] = [:]
        if let raw = dict["features"] as? [String: Any] {
            for (key, value) in raw {
                features[SideSign.Feature(rawValue: key)] = "\(value)"
            }
        }
        return SideSign.AppID(
            identifier: dict["app_id_id"] as? String ?? "",
            name: dict["name"] as? String ?? "",
            bundleIdentifier: dict["identifier"] as? String ?? "",
            features: features
        )
    }

    func rustMapAppGroup(_ dict: [String: Any]) -> SideSign.AppGroup {
        SideSign.AppGroup(
            name: dict["name"] as? String ?? "",
            identifier: dict["identifier"] as? String ?? "",
            groupID: dict["application_group"] as? String ?? ""
        )
    }

    // MARK: - 組合操作

    func rustFetchCertificates(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.X509Certificate] {
        let result = try await rustDevOp("list_certs", params: ["team_id": team.identifier], session: session)
        let dicts = result["certs"] as? [[String: Any]] ?? []
        return dicts.compactMap(rustMapCertificate)
    }

    /// 建證書：本地產生金鑰＋CSR（SideSign CertificateRequest，純本地），
    /// CSR 經 Rust 送 Apple，再輪詢證書清單找新出現的那張組回 KeyStore。
    func rustCreateCertificate(team: SideSign.Team, machineName: String, session: SideSign.Session) async throws -> SideSign.KeyStore {
        let certRequest = try SideSign.CertificateRequest(machineName: machineName)
        let csr = String(decoding: certRequest.csrData, as: UTF8.self)
        let beforeSerials = Set(try await rustFetchCertificates(team: team, session: session).map { $0.serialNumberHex.uppercased() })
        _ = try await rustDevOp("submit_csr", params: [
            "team_id": team.identifier,
            "csr_content": csr,
            "machine_name": machineName,
        ], session: session)
        for _ in 0..<10 {
            let certs = try await rustFetchCertificates(team: team, session: session)
            if let fresh = certs.first(where: { !beforeSerials.contains($0.serialNumberHex.uppercased()) }) {
                let keyStore = SideSign.KeyStore(certificate: fresh, privateKey: certRequest.privateKey)
                saveActiveCertificate(keyStore)
                return keyStore
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw SigningError.certificateFailed("已送出 CSR，但證書清單裡找不到新證書")
    }

    // MARK: - Developer Portal 頁面用（DeveloperPortalService 分流）

    func rustTeams(account: SideSign.Account, session: SideSign.Session) async throws -> [SideSign.Team] {
        let anisette = session.anisetteData
        return try await EiliRustAuthService.shared.fetchTeams(
            token: session.authToken, adsid: session.dsid, account: account,
            fetchAnisette: { _ in anisette }
        )
    }

    func rustListAppIDs(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.AppID] {
        let result = try await rustDevOp("list_app_ids", params: ["team_id": team.identifier], session: session)
        return (result["app_ids"] as? [[String: Any]] ?? []).map(rustMapAppID)
    }

    func rustListAppGroups(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.AppGroup] {
        let result = try await rustDevOp("list_app_groups", params: ["team_id": team.identifier], session: session)
        return (result["groups"] as? [[String: Any]] ?? []).map(rustMapAppGroup)
    }

    func rustListDevices(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.Device] {
        let result = try await rustDevOp("list_devices", params: ["team_id": team.identifier], session: session)
        return (result["devices"] as? [[String: Any]] ?? []).map(rustMapDevice)
    }

    func rustMapListedProfile(_ dict: [String: Any]) -> SideSign.ListedProvisioningProfile? {
        guard let name = dict["name"] as? String, !name.isEmpty,
              let uuid = UUID(uuidString: dict["uuid"] as? String ?? "") else { return nil }
        let expire = ISO8601DateFormatter().date(from: dict["date_expire_iso"] as? String ?? "") ?? .distantPast
        return SideSign.ListedProvisioningProfile(
            provisioningProfileId: (dict["provisioning_profile_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            name: name,
            status: (dict["status"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            type: (dict["type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            uuid: uuid,
            dateExpire: expire,
            appId: SideSign.AppIDPayload(
                appIdId: (dict["app_id_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                identifier: (dict["bundle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                prefix: nil,
                name: nil
            ),
            deviceIds: dict["device_ids"] as? [String],
            isFreeProvisioningProfile: dict["is_free"] as? Bool,
            isTeamProfile: dict["is_team_profile"] as? Bool
        )
    }

    func rustListProfiles(team: SideSign.Team, session: SideSign.Session) async throws -> [SideSign.ListedProvisioningProfile] {
        let result = try await rustDevOp("list_profiles", params: ["team_id": team.identifier], session: session)
        return (result["profiles"] as? [[String: Any]] ?? []).compactMap(rustMapListedProfile)
    }

    func rustProfileFromResult(_ result: [String: Any]) throws -> SideSign.ProvisioningProfile {
        guard let b64 = result["profile_b64"] as? String, let data = Data(base64Encoded: b64) else {
            throw SigningError.profileFailed("Rust Portal 未回傳 profile")
        }
        return try SideSign.ProvisioningProfile(data: data)
    }

    func rustCreateProfile(name: String, appID: SideSign.AppID, certificateIDs: [String], deviceIDs: [String], team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile {
        let result = try await rustDevOp("create_profile", params: [
            "team_id": team.identifier, "name": name, "app_id_id": appID.identifier,
            "certificate_ids": certificateIDs, "device_ids": deviceIDs,
        ], session: session)
        return try rustProfileFromResult(result)
    }

    func rustUpdateProfile(profileID: String, name: String, appIDId: String, certificateIDs: [String], deviceIDs: [String], team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile {
        let result = try await rustDevOp("update_profile", params: [
            "team_id": team.identifier, "provisioning_profile_id": profileID, "name": name, "app_id_id": appIDId,
            "certificate_ids": certificateIDs, "device_ids": deviceIDs,
        ], session: session)
        return try rustProfileFromResult(result)
    }

    func rustDownloadProfile(profileID: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile {
        let result = try await rustDevOp("download_profile", params: [
            "team_id": team.identifier, "provisioning_profile_id": profileID,
        ], session: session)
        return try rustProfileFromResult(result)
    }

    func rustGenerateProfile(appID: SideSign.AppID, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.ProvisioningProfile {
        let result = try await rustDevOp("download_team_profile", params: [
            "team_id": team.identifier, "app_id_id": appID.identifier,
            "identifier": appID.bundleIdentifier, "name": appID.name,
        ], session: session)
        return try rustProfileFromResult(result)
    }

    func rustDeleteProfile(profileID: String, team: SideSign.Team, session: SideSign.Session) async throws {
        _ = try await rustDevOp("delete_profile", params: [
            "team_id": team.identifier, "provisioning_profile_id": profileID,
        ], session: session)
    }

    func rustCreateAppGroup(name: String, groupIdentifier: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.AppGroup {
        let result = try await rustDevOp("add_app_group", params: [
            "team_id": team.identifier, "name": name, "identifier": groupIdentifier,
        ], session: session)
        guard let dict = result["group"] as? [String: Any] else {
            throw SigningError.signingFailed("Rust Portal 未回傳 App Group")
        }
        return rustMapAppGroup(dict)
    }

    func rustUpdateAppGroup(_ group: SideSign.AppGroup, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.AppGroup {
        let result = try await rustDevOp("update_app_group", params: [
            "team_id": team.identifier, "name": group.name,
            "application_group": group.groupID, "group_identifier": group.identifier,
        ], session: session)
        guard let dict = result["group"] as? [String: Any] else {
            throw SigningError.signingFailed("Rust Portal 未回傳 App Group")
        }
        return rustMapAppGroup(dict)
    }

    func rustDeleteAppGroup(_ group: SideSign.AppGroup, team: SideSign.Team, session: SideSign.Session) async throws {
        _ = try await rustDevOp("delete_app_group", params: [
            "team_id": team.identifier, "application_group": group.groupID,
        ], session: session)
    }

    func rustAssignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.AppID {
        let updated = try await rustDevOp("update_app_id", params: [
            "team_id": team.identifier, "app_id_id": appID.identifier,
            "identifier": appID.bundleIdentifier, "name": appID.name,
            "features": [SideSign.Feature.appGroups.rawValue: "true"],
        ], session: session)
        for group in groups {
            _ = try await rustDevOp("assign_app_group", params: [
                "team_id": team.identifier, "app_id_id": appID.identifier,
                "application_group": group.groupID, "group_identifier": group.identifier, "group_name": group.name,
            ], session: session)
        }
        if let dict = updated["app_id"] as? [String: Any] {
            return rustMapAppID(dict)
        }
        return appID
    }

    func rustRegisterDevice(name: String, identifier: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.Device {
        let result = try await rustDevOp("add_device", params: [
            "team_id": team.identifier, "name": name, "device_number": identifier,
        ], session: session)
        guard let dict = result["device"] as? [String: Any] else {
            throw SigningError.signingFailed("Rust Portal 未回傳設備")
        }
        return rustMapDevice(dict)
    }

    func rustUpdateDevice(_ device: SideSign.Device, name: String, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.Device {
        let result = try await rustDevOp("update_device", params: [
            "team_id": team.identifier, "name": name, "device_number": device.identifier,
            "device_id": device.deviceID ?? "", "status": device.status ?? "",
        ], session: session)
        guard let dict = result["device"] as? [String: Any] else {
            throw SigningError.signingFailed("Rust Portal 未回傳設備")
        }
        var mapped = rustMapDevice(dict)
        mapped.type = device.type
        return mapped
    }

    func rustDisableDevice(_ device: SideSign.Device, team: SideSign.Team, session: SideSign.Session) async throws -> SideSign.Device {
        _ = try await rustDevOp("disable_device", params: [
            "team_id": team.identifier, "device_number": device.identifier,
            "device_id": device.deviceID ?? "", "name": device.name,
        ], session: session)
        var updated = device
        updated.status = "d"
        return updated
    }

    func rustDeleteDevice(_ device: SideSign.Device, team: SideSign.Team, session: SideSign.Session) async throws {
        _ = try await rustDevOp("delete_device", params: [
            "team_id": team.identifier, "device_number": device.identifier,
            "device_id": device.deviceID ?? "",
        ], session: session)
    }
}
