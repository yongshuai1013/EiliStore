import Foundation
import SideSign

/// PaxStore 登入服務（用 SideSign，跟 SideStore 同款）
public final class PaxAuthService {
    public static let shared = PaxAuthService()
    
    private init() {}
    
    // MARK: - Keychain Keys
    
    private enum KeychainKey {
        static let session = "paxstore.auth.session"
        static let appleID = "paxstore.auth.appleID"
        static let anisetteIdentifier = "paxstore.anisette.identifier"
        static let adiBlob = "paxstore.anisette.adiblob"
    }
    
    /// 當前已登入的 Apple ID（從 Keychain 讀）
    public var currentAppleID: String? {
        if let session: SideSign.AuthSession = KeychainHelper.loadCodable(
            SideSign.AuthSession.self,
            forKey: KeychainKey.session
        ) {
            let appleID = session.account.appleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !appleID.isEmpty { return appleID }
        }
        return KeychainHelper.loadString(forKey: KeychainKey.appleID)
    }
    
    /// 是否有已保存的登入 session
    public var hasSavedSession: Bool {
        KeychainHelper.load(forKey: KeychainKey.session) != nil
    }

    /// Session transfer must restore the account identifier used by the app's login-state checks.
    /// Keep the raw Session bytes unchanged and roll back both Keychain entries if either write fails.
    func importSession(_ data: Data, session: SideSign.AuthSession) -> String? {
        let appleID = session.account.appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appleID.isEmpty else { return nil }

        let previousSession = KeychainHelper.load(forKey: KeychainKey.session)
        let previousAppleID = KeychainHelper.load(forKey: KeychainKey.appleID)
        guard KeychainHelper.save(data, forKey: KeychainKey.session),
              KeychainHelper.saveString(appleID, forKey: KeychainKey.appleID) else {
            restoreKeychainItem(previousSession, forKey: KeychainKey.session)
            restoreKeychainItem(previousAppleID, forKey: KeychainKey.appleID)
            return nil
        }
        return appleID
    }

    private func restoreKeychainItem(_ data: Data?, forKey key: String) {
        if let data {
            _ = KeychainHelper.save(data, forKey: key)
        } else {
            _ = KeychainHelper.delete(forKey: key)
        }
    }
    
    /// 登入時用的 anisette 伺服器列表（自動輪換開→按優先順序 failover）
    private var anisetteServers: [URL] {
        let urls = AnisetteServerManager.shared.serversForLogin()
        return urls.isEmpty ? [URL(string: "https://ani.sidestore.zip")!] : urls
    }
    
    /// 登入（一次 authenticate 內完成 2FA；只有選擇發送方式才會要求發碼）
    public func login(appleID: String, password: String, codeProvider: TwoFACodeProvider = TwoFACodeProvider()) async throws -> Bool {
        defer { codeProvider.cancel() }
        try Task.checkCancellation()
        // 1. 拿 anisette（穩定身份）
        let identifier = resolveIdentifier()
        let existingBlob: Data? = loadADIBlob()
        
        let manager = SideSign.AnisetteDataManager.shared
        let (anisetteData, newBlob) = try await manager.fetchAnisetteDataWithFailover(
            servers: anisetteServers,
            identifier: identifier,
            existingAdiBlob: existingBlob
        )
        
        try Task.checkCancellation()
        guard !codeProvider.isCancelled else { throw CancellationError() }

        if let newBlob = newBlob {
            saveADIBlob(newBlob)
        }
        
        // 2. SideSign 登入（2FA 在同一次調用內等待輸入）
        let portal = SideSign.DeveloperPortal.shared
        
        let verificationHandler: SideSign.DeveloperPortal.VerificationHandler = { request in
            try Task.checkCancellation()
            guard !codeProvider.isCancelled else { throw CancellationError() }
            switch request {
            case .trustedDevice(let error):
                codeProvider.log("等待受信任設備驗證碼")
                return .verificationCode(try await codeProvider.awaitCode(mode: .trustedDevice, rejected: error != nil))
            case .sms(_, _, let error):
                codeProvider.log("等待簡訊驗證碼")
                return .verificationCode(try await codeProvider.awaitCode(mode: .sms, rejected: error != nil))
            case .voice(_, _, let error):
                codeProvider.log("等待語音驗證碼")
                return .verificationCode(try await codeProvider.awaitCode(mode: .voice, rejected: error != nil))
            case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
                codeProvider.log("等待選擇驗證方式")
                let method = try await codeProvider.awaitMethod(phoneNumbers: phoneNumbers, preferred: preferredMode)
                try Task.checkCancellation()
                guard !codeProvider.isCancelled else { throw CancellationError() }
                switch method {
                case .trustedDevice:
                    return .requestTrustedDevice
                case .sms(let phoneID):
                    return .requestSMS(phoneID: phoneID)
                case .voice(let phoneID):
                    return .requestVoice(phoneID: phoneID)
                }
            }
        }

        let session = try await portal.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteData,
            xcodeVersion: "27.0 (27A242)",
            verificationHandler: verificationHandler
        )
        
        // 已取消的流程不得保存 session。
        try Task.checkCancellation()
        guard !codeProvider.isCancelled else { throw CancellationError() }

        // 保存 session 到 Keychain
        guard KeychainHelper.saveCodable(session, forKey: KeychainKey.session) else {
            throw LoginError.sessionSaveFailed
        }
        guard KeychainHelper.saveString(appleID, forKey: KeychainKey.appleID) else {
            KeychainHelper.delete(forKey: KeychainKey.session)
            throw LoginError.sessionSaveFailed
        }
        codeProvider.log("登入資料已安全保存")
        
        print("[PaxStore] 登入成功")
        return true
    }
    
    private enum LoginError: Error {
        case sessionSaveFailed
    }

    /// 不把 Apple 回應內容、電話資料或伺服器 payload 顯示／記錄到 UI。
    static func loginErrorMessage(for error: Error) -> String {
        if error is CancellationError { return "登入已取消" }
        if error is LoginError { return "無法安全保存登入資料，請重試。" }
        if let portalError = error as? DeveloperPortalError {
            switch portalError {
            case .userCancelled:
                return "登入已取消"
            case .tooManyAttempts:
                return "Apple 暫時限制登入或發送驗證碼，請稍後再試，避免連續要求發碼。"
            case .incorrectCredentials:
                return "Apple 未接受登入資料，請檢查帳號及密碼後再試。"
            default:
                break
            }
        }
        if error is URLError { return "網路請求未完成，請檢查連線後再試。" }
        return "登入未完成，可能是 Apple 或 Anisette 服務暫時無法回應，請稍後再試。"
    }

    // MARK: - Session 恢復與登出
    
    /// 從 Keychain 恢復 session（App 啟動時調用）
    public func restoreSession() -> Bool {
        guard let _: SideSign.AuthSession = KeychainHelper.loadCodable(SideSign.AuthSession.self, forKey: KeychainKey.session),
              currentAppleID != nil else {
            return false
        }
        print("[PaxStore] 已從 Keychain 恢復登入狀態")
        return true
    }
    
    /// 登出：清除 Keychain 中的 session（保留 anisette 數據）
    public func logout() {
        KeychainHelper.delete(forKey: KeychainKey.session)
        KeychainHelper.delete(forKey: KeychainKey.appleID)
        print("[PaxStore] 已登出，session 已清除")
    }
    
    // MARK: - Reset
    
    /// 清除本地 Anisette 數據（對應 SideStore 的 Reset adi.pb）
    public func resetAnisette() {
        KeychainHelper.delete(forKey: KeychainKey.anisetteIdentifier)
        KeychainHelper.delete(forKey: KeychainKey.adiBlob)
        UserDefaults.standard.removeObject(forKey: "paxstore.anisette.identifier")
        UserDefaults.standard.removeObject(forKey: "paxstore.anisette.adiblob")
        print("[PaxStore] Anisette 數據已清除")
    }
    
    // MARK: - Anisette 身份（Keychain 持久化）
    
    private func resolveIdentifier() -> UUID {
        let key = KeychainKey.anisetteIdentifier
        if let uuidString = KeychainHelper.loadString(forKey: key),
           let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        if let uuidString = UserDefaults.standard.string(forKey: "paxstore.anisette.identifier"),
           let uuid = UUID(uuidString: uuidString) {
            KeychainHelper.saveString(uuid.uuidString, forKey: key)
            UserDefaults.standard.removeObject(forKey: "paxstore.anisette.identifier")
            return uuid
        }
        let newUUID = UUID()
        KeychainHelper.saveString(newUUID.uuidString, forKey: key)
        return newUUID
    }
    
    private func loadADIBlob() -> Data? {
        if let data = KeychainHelper.load(forKey: KeychainKey.adiBlob) {
            return data
        }
        if let data = UserDefaults.standard.data(forKey: "paxstore.anisette.adiblob") {
            KeychainHelper.save(data, forKey: KeychainKey.adiBlob)
            UserDefaults.standard.removeObject(forKey: "paxstore.anisette.adiblob")
            return data
        }
        return nil
    }
    
    private func saveADIBlob(_ data: Data) {
        KeychainHelper.save(data, forKey: KeychainKey.adiBlob)
    }
}
