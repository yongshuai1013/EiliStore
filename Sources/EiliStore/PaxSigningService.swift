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
        
        // 從 Keychain 取穩定的 anisette 身份
        guard let uuidString = KeychainHelper.loadString(forKey: "paxstore.anisette.identifier"),
              let identifier = UUID(uuidString: uuidString) else {
            throw SigningError.certificateFailed("找不到 anisette 身份，請重新登入")
        }
        let existingBlob = KeychainHelper.load(forKey: "paxstore.anisette.adiblob")
        
        // 取新鮮 anisette
        let servers = AnisetteServerManager.shared.serversForLogin()
        let urls = servers.isEmpty ? [URL(string: "https://ani.sidestore.zip")!] : servers
        let manager = SideSign.AnisetteDataManager.shared
        let (freshAnisette, newBlob) = try await manager.fetchAnisetteDataWithFailover(
            servers: urls,
            identifier: identifier,
            existingAdiBlob: existingBlob
        )
        if let newBlob = newBlob {
            KeychainHelper.save(newBlob, forKey: "paxstore.anisette.adiblob")
        }
        
        // 換上新鮮 anisette
        var freshSession = authSession.session
        freshSession.anisetteData = freshAnisette
        
        return (authSession.account, freshSession)
    }
    
    // MARK: - Teams
    
    /// 獲取該 Apple ID 下的所有 Team
    public func fetchTeams() async throws -> [SideSign.Team] {
        let (account, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
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
        let portal = SideSign.DeveloperPortal.shared
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
        let portal = SideSign.DeveloperPortal.shared
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
        let portal = SideSign.DeveloperPortal.shared
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
