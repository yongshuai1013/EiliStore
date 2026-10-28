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
}
