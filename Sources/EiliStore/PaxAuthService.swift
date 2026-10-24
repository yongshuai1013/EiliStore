import Foundation
import SideSign

/// EiliStore 登入接線：參照 SideStore 的流程語義，使用 SideSign 而不複製其 app 實作。
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
        UserDefaults.standard.set(EiliAnisetteMode.remote.rawValue, forKey: EiliAnisetteMode.sessionKey)
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
    public func login(appleID: String, password: String, codeProvider: TwoFACodeProvider = TwoFACodeProvider(), diagnosticAttempt: UUID? = nil) async throws -> Bool {
        let attempt = diagnosticAttempt ?? EiliLoginDiagnostics.shared.begin(onDevice: EiliAnisetteMode.selected == .onDevice)
        EiliLoginDiagnostics.record(.authServiceEntered, for: attempt)
        // Diagnostics must not wrap the login in a new async TaskLocal scope.
        // Pass the ID explicitly so a missing runtime context cannot hide all stages.
        do {
            let result = try await performLogin(appleID: appleID, password: password, codeProvider: codeProvider, diagnosticAttempt: attempt)
            EiliLoginDiagnostics.shared.finish(.succeeded, for: attempt)
            return result
        } catch {
            let cancelled: Bool
            if error is CancellationError { cancelled = true }
            else if case DeveloperPortalError.userCancelled = error { cancelled = true }
            else { cancelled = false }
            EiliLoginDiagnostics.shared.finish(cancelled ? .cancelled : .failed, for: attempt)
            throw error
        }
    }

    private func performLogin(appleID: String, password: String, codeProvider: TwoFACodeProvider, diagnosticAttempt: UUID) async throws -> Bool {
        defer { codeProvider.cancel() }
        EiliLoginDiagnostics.record(.loginStarted, for: diagnosticAttempt)
        codeProvider.log("開始登入：\(appleID)")
        try Task.checkCancellation()
        // 1. 拿 anisette（穩定身份）
        let identifier = resolveIdentifier()
        let existingBlob: Data? = loadADIBlob()
        let anisetteMode = EiliAnisetteMode.selected
        EiliLoginDiagnostics.record(.configurationLoading, for: diagnosticAttempt)
        let clientConfiguration = try await EiliAnisetteClientConfigurationStore.shared.load()
        let portal = try await EiliSideSignClientConfigurationStore.shared.makePortal()
        EiliLoginDiagnostics.record(.configurationReady, for: diagnosticAttempt)
        if anisetteMode == .onDevice {
            codeProvider.log("步驟 1/3：生成本地 anisette（ODA）…")
        } else {
            // 把實際設定印進日誌：選中的伺服器與自動輪換狀態。輪換關閉時
            // 選中即所用；開啟時實際應答者以下一行 anisette 就緒的
            // MD-M／RINFO 指紋為準。
            let selectedServer = AnisetteServerManager.shared.selectedServer
            let serverHost = selectedServer.nsURL?.host ?? selectedServer.url
            let rotationState = AnisetteServerManager.shared.autoRotationEnabled ? "開" : "關"
            codeProvider.log("步驟 1/3：向遠端伺服器取得 anisette（已選：\(selectedServer.name) · \(serverHost)，自動輪換：\(rotationState)）…")
        }
        
        let anisetteData = try await EiliAnisetteService.shared.fetch(
            remoteIdentifier: identifier,
            remoteBlob: existingBlob,
            servers: anisetteServers,
            mode: anisetteMode,
            configuration: clientConfiguration,
            diagnosticAttempt: diagnosticAttempt
        )
        
        EiliLoginDiagnostics.record(.anisetteReady, for: diagnosticAttempt)
        codeProvider.log("anisette 就緒：MD=\(anisetteData.oneTimePassword.prefix(10))… MD-M=\(anisetteData.machineID.prefix(10))… RINFO=\(anisetteData.routingInfo)")
        try Task.checkCancellation()
        guard !codeProvider.isCancelled else { throw CancellationError() }

        // 2. SideSign 登入（2FA 在同一次調用內等待輸入）
        // Keep the same immutable header snapshot throughout this 2FA flow.
        
        let verificationHandler: SideSign.DeveloperPortal.VerificationHandler = { request in
            try Task.checkCancellation()
            guard !codeProvider.isCancelled else { throw CancellationError() }
            EiliLoginDiagnostics.record(.verificationWaiting, for: diagnosticAttempt)
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

        EiliLoginDiagnostics.record(.authenticationStarted, for: diagnosticAttempt)
        codeProvider.log("步驟 2/3：向 Apple 登入（SRP）…")
        let session = try await portal.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteData,
            xcodeVersion: clientConfiguration.resolvedXcodeVersion(),
            verificationHandler: verificationHandler
        )
        
        EiliLoginDiagnostics.record(.authenticationReturned, for: diagnosticAttempt)
        // 已取消的流程不得保存 session。
        try Task.checkCancellation()
        guard !codeProvider.isCancelled else { throw CancellationError() }

        // SideSign 必須先回傳真正的 AuthSession；兩項保存視為同一筆交易。
        // 寫入失敗不能破壞既有登入，也不能留下新舊帳號混合的狀態。
        EiliLoginDiagnostics.record(.sessionSaving, for: diagnosticAttempt)
        let previousSession = KeychainHelper.load(forKey: KeychainKey.session)
        let previousAppleID = KeychainHelper.load(forKey: KeychainKey.appleID)
        guard KeychainHelper.saveCodable(session, forKey: KeychainKey.session),
              KeychainHelper.saveString(appleID, forKey: KeychainKey.appleID) else {
            restoreKeychainItem(previousSession, forKey: KeychainKey.session)
            restoreKeychainItem(previousAppleID, forKey: KeychainKey.appleID)
            throw LoginError.sessionSaveFailed
        }
        UserDefaults.standard.set(anisetteMode.rawValue, forKey: EiliAnisetteMode.sessionKey)
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
        if let anisetteError = error as? EiliAnisetteError { return anisetteError.localizedDescription }
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
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)
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
