import Foundation
import SideSign

/// 2FA 方式選擇
public enum TwoFactorMethod: Sendable {
    case trustedDevice
    case sms(phoneID: String)
    case voice(phoneID: String)
}

/// 2FA 代碼提供者：handler 在同一次 authenticate() 內等待 UI 輸入，不會重發 SMS
public final class TwoFACodeProvider: Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var pendingCode: String?
    private var _onCodeRequired: (@Sendable () -> Void)?
    private var _onLog: (@Sendable (String) -> Void)?
    
    // 方式選擇
    private var methodContinuation: CheckedContinuation<TwoFactorMethod, Never>?
    private var pendingMethod: TwoFactorMethod?
    private var _onMethodRequired: (@Sendable ([TrustedPhoneNumber], TwoFactorDeliveryMode) -> Void)?
    
    public init() {}
    
    /// UI 設置日誌回調
    public var onLog: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onLog } }
        set { lock.withLock { _onLog = newValue } }
    }
    
    public func log(_ message: String) {
        if let callback = lock.withLock({ _onLog }) {
            callback(message)
        }
        print("[PaxStore] \(message)")
    }
    
    /// UI 設置「需要驗證碼時」的回調（用來顯示輸入框）
    public var onCodeRequired: (@Sendable () -> Void)? {
        get { lock.withLock { _onCodeRequired } }
        set { lock.withLock { _onCodeRequired = newValue } }
    }
    
    /// UI 設置「需要選擇 2FA 方式時」的回調
    public var onMethodRequired: (@Sendable ([TrustedPhoneNumber], TwoFactorDeliveryMode) -> Void)? {
        get { lock.withLock { _onMethodRequired } }
        set { lock.withLock { _onMethodRequired = newValue } }
    }
    
    /// Handler 調用：等待用戶選擇 2FA 方式
    public func awaitMethod(phoneNumbers: [TrustedPhoneNumber], preferred: TwoFactorDeliveryMode) async -> TwoFactorMethod {
        if let callback = lock.withLock({ _onMethodRequired }) {
            callback(phoneNumbers, preferred)
        }
        if let method = lock.withLock({ () -> TwoFactorMethod? in
            let m = pendingMethod
            pendingMethod = nil
            return m
        }) {
            return method
        }
        return await withCheckedContinuation { cont in
            lock.withLock {
                if let method = pendingMethod {
                    pendingMethod = nil
                    cont.resume(returning: method)
                } else {
                    methodContinuation = cont
                }
            }
        }
    }
    
    /// UI 調用：用戶選了方式
    public func submitMethod(_ method: TwoFactorMethod) {
        let cont: CheckedContinuation<TwoFactorMethod, Never>? = lock.withLock {
            if let c = methodContinuation {
                methodContinuation = nil
                return c
            } else {
                pendingMethod = method
                return nil
            }
        }
        cont?.resume(returning: method)
    }
    
    /// Handler 調用：等待用戶輸入驗證碼（只會在同一次登入內等待，不重發 SMS）
    public func awaitCode() async -> String {
        // 先通知 UI 顯示輸入框
        if let callback = lock.withLock({ _onCodeRequired }) {
            callback()
        }
        // 檢查是否有已提交但還沒取走的碼（處理競態）
        if let code = lock.withLock({ () -> String? in
            let c = pendingCode
            pendingCode = nil
            return c
        }) {
            return code
        }
        return await withCheckedContinuation { cont in
            lock.withLock {
                // 再次檢查（雙重檢查鎖定）
                if let code = pendingCode {
                    pendingCode = nil
                    cont.resume(returning: code)
                } else {
                    continuation = cont
                }
            }
        }
    }
    
    /// UI 調用：用戶輸完碼，喚醒等待中的 handler（或暫存，等 handler 來取）
    public func submitCode(_ code: String) {
        let cont: CheckedContinuation<String, Never>? = lock.withLock {
            if let c = continuation {
                continuation = nil
                return c
            } else {
                // handler 還沒掛起，先存起來
                pendingCode = code
                return nil
            }
        }
        cont?.resume(returning: code)
    }
}

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
        KeychainHelper.loadString(forKey: KeychainKey.appleID)
    }
    
    /// 是否有已保存的登入 session
    public var hasSavedSession: Bool {
        KeychainHelper.load(forKey: KeychainKey.session) != nil
    }
    
    /// 登入時用的 anisette 伺服器列表（自動輪換開→按優先順序 failover）
    private var anisetteServers: [URL] {
        let urls = AnisetteServerManager.shared.serversForLogin()
        return urls.isEmpty ? [URL(string: "https://ani.sidestore.zip")!] : urls
    }
    
    /// 登入（一次 authenticate 內完成 2FA，不會重發 SMS）
    public func login(appleID: String, password: String, codeProvider: TwoFACodeProvider = TwoFACodeProvider()) async throws -> Bool {
        // 1. 拿 anisette（穩定身份）
        let identifier = resolveIdentifier()
        let existingBlob: Data? = loadADIBlob()
        
        let manager = SideSign.AnisetteDataManager.shared
        let (anisetteData, newBlob) = try await manager.fetchAnisetteDataWithFailover(
            servers: anisetteServers,
            identifier: identifier,
            existingAdiBlob: existingBlob
        )
        
        if let newBlob = newBlob {
            saveADIBlob(newBlob)
        }
        
        // 2. SideSign 登入（2FA 在同一次調用內等待輸入）
        let portal = SideSign.DeveloperPortal.shared
        
        let verificationHandler: SideSign.DeveloperPortal.VerificationHandler = { request in
            switch request {
            case .trustedDevice(let error):
                codeProvider.log("收到 trustedDevice 請求, error: \(error ?? "無")")
                let code = await codeProvider.awaitCode()
                let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                codeProvider.log("提交設備碼: \(cleanCode.count) 位")
                return .verificationCode(cleanCode)
            case .sms(let phoneNumbers, let activeID, let error):
                codeProvider.log("收到 sms 請求, activeID: \(activeID), 電話數: \(phoneNumbers.count), error: \(error ?? "無")")
                let code = await codeProvider.awaitCode()
                let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                codeProvider.log("提交 SMS 碼: \(cleanCode.count) 位到 \(activeID)")
                return .verificationCode(cleanCode)
            case .voice(let phoneNumbers, let activeID, let error):
                codeProvider.log("收到 voice 請求, activeID: \(activeID), error: \(error ?? "無")")
                let code = await codeProvider.awaitCode()
                let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                codeProvider.log("提交語音碼: \(cleanCode.count) 位")
                return .verificationCode(cleanCode)
            case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
                codeProvider.log("選擇 2FA 方式, 建議: \(preferredMode), 電話數: \(phoneNumbers.count)")
                for phone in phoneNumbers {
                    codeProvider.log("  電話: id=\(phone.id), number=\(phone.number)")
                }
                // 彈窗讓用戶手動選擇（跟 SideStore 一樣）
                let method = await codeProvider.awaitMethod(phoneNumbers: phoneNumbers, preferred: preferredMode)
                switch method {
                case .trustedDevice:
                    codeProvider.log("用戶選擇: 受信任設備")
                    return .requestTrustedDevice
                case .sms(let phoneID):
                    codeProvider.log("用戶選擇: SMS (phoneID=\(phoneID))")
                    return .requestSMS(phoneID: phoneID)
                case .voice(let phoneID):
                    codeProvider.log("用戶選擇: 語音 (phoneID=\(phoneID))")
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
        
        // 保存 session 到 Keychain
        let saved = KeychainHelper.saveCodable(session, forKey: KeychainKey.session)
        KeychainHelper.saveString(appleID, forKey: KeychainKey.appleID)
        codeProvider.log("Session 已保存到 Keychain: \(saved)")
        
        print("[PaxStore] 登入成功")
        return true
    }
    
    // MARK: - Session 恢復與登出
    
    /// 從 Keychain 恢復 session（App 啟動時調用）
    public func restoreSession() -> Bool {
        guard let _: SideSign.AuthSession = KeychainHelper.loadCodable(SideSign.AuthSession.self, forKey: KeychainKey.session),
              let appleID = currentAppleID else {
            return false
        }
        print("[PaxStore] 從 Keychain 恢復 session: \(appleID)")
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
