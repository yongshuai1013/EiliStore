import Foundation
import SideSign

/// PaxStore 簽名服務：封裝 SideSign 的 DeveloperPortal API
public final class PaxSigningService {
    public static let shared = PaxSigningService()
    
    private init() {}
    
    // MARK: - Session
    
    /// 從 Keychain 讀取已保存的 AuthSession
    private func loadSession() throws -> SideSign.AuthSession {
        guard let session: SideSign.AuthSession = KeychainHelper.loadCodable(
            SideSign.AuthSession.self,
            forKey: "paxstore.auth.session"
        ) else {
            throw SigningError.notLoggedIn
        }
        return session
    }
    
    /// 獲取帶新鮮 anisette 的 session（每次 DeveloperPortal 調用前必須刷新）
    /// 原因：anisette 含一次性 OTP，登入時已消費，重用會導致 Apple 回 1100
    func sessionWithFreshAnisette() async throws -> (account: SideSign.Account, session: SideSign.Session) {
        let authSession = try loadSession()
        let anisetteMode = EiliAnisetteMode.savedSessionMode
        let clientConfiguration = try await EiliAnisetteClientConfigurationStore.shared.load()
        
        // 從 Keychain 取穩定的 anisette 身份
        let remoteIdentifier = KeychainHelper.loadString(forKey: "paxstore.anisette.identifier")
            .flatMap(UUID.init(uuidString:))
        guard anisetteMode == .onDevice || remoteIdentifier != nil else {
            throw SigningError.certificateFailed("找不到 anisette 身份，請重新登入")
        }
        let existingBlob = KeychainHelper.load(forKey: "paxstore.anisette.adiblob")
        
        // 取新鮮 anisette
        let servers = AnisetteServerManager.shared.serversForLogin()
        let freshAnisette = try await EiliAnisetteService.shared.fetch(
            remoteIdentifier: remoteIdentifier ?? UUID(),
            remoteBlob: existingBlob,
            servers: servers,
            mode: anisetteMode,
            configuration: clientConfiguration
        )
        
        // 換上新鮮 anisette
        var freshSession = authSession.session
        freshSession.anisetteData = freshAnisette
        freshSession.xcodeVersion = clientConfiguration.resolvedXcodeVersion(fallback: freshSession.xcodeVersion)
        
        return (authSession.account, freshSession)
    }
    
    // MARK: - Session 健康檢查（帳號頁專用）

    /// 健康檢查的失敗階段：取新鮮 anisette／組 Portal 是第一段，Portal
    /// 本身回應是第二段。頁面顯示「未知」時靠這層區分真因。
    public enum SessionCheckError: LocalizedError {
        case preparationFailed(String)
        case portalFailed(String)

        public var errorDescription: String? {
            switch self {
            case .preparationFailed(let detail): return "準備驗證失敗（anisette／設定）：\(detail)"
            case .portalFailed(let detail): return "Portal 驗證失敗：\(detail)"
            }
        }
    }

    /// 與 fetchTeams 相同的驗證，但把失敗段落包進錯誤訊息（其他呼叫方
    /// 仍用原 fetchTeams，行為不變）。
    public func fetchTeamsForSessionCheck() async throws -> [SideSign.Team] {
        let account: SideSign.Account
        let session: SideSign.Session
        let portal: SideSign.DeveloperPortal?
        do {
            (account, session) = try await sessionWithFreshAnisette()
            portal = EiliLoginMethod.savedSessionOrigin == .rust
                ? nil
                : try await EiliSideSignClientConfigurationStore.shared.makePortal()
        } catch {
            throw SessionCheckError.preparationFailed(error.localizedDescription)
        }
        do {
            if let portal {
                return try await portal.fetchTeams(for: account, session: session)
            }
            return try await rustFetchTeams(account: account, session: session)
        } catch {
            throw SessionCheckError.portalFailed(error.localizedDescription)
        }
    }

    /// B 路線：session 是 Rust 登入領出來的時候，Teams 改走 isideload
    /// 自己的 DeveloperSession（保存的 token＋adsid 重建），不經
    /// SideSign Portal 形狀。anisette 用 sessionWithFreshAnisette 剛換
    /// 上的那份（回調每次回同一份新鮮快照即可，單次請求只取一次）。
    private func rustFetchTeams(account: SideSign.Account, session: SideSign.Session) async throws -> [SideSign.Team] {
        let anisette = session.anisetteData
        return try await EiliRustAuthService.shared.fetchTeams(
            token: session.authToken,
            adsid: session.dsid,
            account: account,
            fetchAnisette: { _ in anisette }
        )
    }

    // MARK: - Teams

    /// 獲取該 Apple ID 下的所有 Team
    public func fetchTeams() async throws -> [SideSign.Team] {
        let (account, session) = try await sessionWithFreshAnisette()
        if EiliLoginMethod.savedSessionOrigin == .rust {
            let teams = try await rustFetchTeams(account: account, session: session)
            print("[PaxStore] 找到 \(teams.count) 個 Team（Rust Portal）")
            return teams
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        let teams = try await portal.fetchTeams(
            for: account,
            session: session
        )
        print("[PaxStore] 找到 \(teams.count) 個 Team")
        return teams
    }
    
    // MARK: - Certificates
    
    /// 獲取指定 Team 下的所有證書
    public func fetchCertificates(for team: SideSign.Team) async throws -> [SideSign.X509Certificate] {
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            let certs = try await rustFetchCertificates(team: team, session: session)
            print("[PaxStore] 找到 \(certs.count) 個證書（Rust Portal）")
            return certs
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        let certs = try await portal.fetchCertificates(
            for: team,
            session: session
        )
        print("[PaxStore] 找到 \(certs.count) 個證書")
        return certs
    }
    
    /// 為指定 Team 創建新的開發證書
    /// - Returns: 包含私鑰的 KeyStore（必須保存好，簽名時要用）
    public func createCertificate(for team: SideSign.Team, machineName: String = "PaxStore") async throws -> SideSign.KeyStore {
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            let keyStore = try await rustCreateCertificate(team: team, machineName: machineName, session: session)
            print("[PaxStore] 證書創建成功（Rust Portal）")
            return keyStore
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        let keyStore = try await portal.addCertificate(
            machineName: machineName,
            type: .development,
            to: team,
            session: session
        )
        print("[PaxStore] 證書創建成功")
        // 自動設為激活證書
        saveActiveCertificate(keyStore)
        return keyStore
    }
    
    // MARK: - Active Local Certificate
    
    private let activeCertP12Key = "paxstore.signing.activeCertP12"
    
    /// 保存激活的本地證書（P12 格式，含私鑰）
    /// KeyStore 本身不是 Codable，用 exportP12() 轉成 Data 存
    public func saveActiveCertificate(_ keyStore: SideSign.KeyStore) {
        do {
            let p12Data = try keyStore.exportP12()
            KeychainHelper.save(p12Data, forKey: activeCertP12Key)
            print("[PaxStore] 已保存激活證書: \(keyStore.certificate.serialNumberHex)")
        } catch {
            print("[PaxStore] 保存證書失敗: \(error)")
        }
    }
    
    /// 讀取激活的本地證書
    public func loadActiveCertificate() -> SideSign.KeyStore? {
        guard let p12Data = KeychainHelper.load(forKey: activeCertP12Key) else {
            return nil
        }
        return try? SideSign.KeyStore(p12Data: p12Data)
    }
    
    /// 讀取激活證書的序列號（用於 UI 判斷）
    public func loadActiveCertificateSerial() -> String? {
        return loadActiveCertificate()?.certificate.serialNumberHex
    }
    
    /// 清除激活的本地證書
    public func clearActiveCertificate() {
        KeychainHelper.delete(forKey: activeCertP12Key)
        print("[PaxStore] 已清除激活證書")
    }
    
    /// 撤銷指定證書
    public func revokeCertificate(_ certificate: SideSign.X509Certificate, for team: SideSign.Team) async throws {
        let (_, session) = try await sessionWithFreshAnisette()
        if isRustSession {
            _ = try await rustDevOp("revoke_cert", params: [
                "team_id": team.identifier,
                "serial_number": certificate.serialNumber,
            ], session: session)
            print("[PaxStore] 證書已撤銷（Rust Portal）")
            return
        }
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        let success = try await portal.revokeCertificate(
            certificate,
            for: team,
            session: session
        )
        if !success {
            throw SigningError.certificateFailed("撤銷返回失敗")
        }
        print("[PaxStore] 證書已撤銷")
    }
}

// MARK: - Errors

public enum SigningError: LocalizedError {
    case notLoggedIn
    case noTeamFound
    case certificateFailed(String)
    case profileFailed(String)
    case signingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "尚未登入，請先登入 Apple ID"
        case .noTeamFound:
            return "找不到可用的 Team"
        case .certificateFailed(let msg):
            return "證書操作失敗：\(msg)"
        case .profileFailed(let msg):
            return "描述文件操作失敗：\(msg)"
        case .signingFailed(let msg):
            return "簽名失敗：\(msg)"
        }
    }
}
