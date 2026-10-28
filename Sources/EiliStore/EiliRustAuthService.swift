import Foundation
import SideSign

/// Rust (isideload) 備用登入的接線層。
///
/// - anisette：沿用 PaxAuthService 同一套 EiliAnisetteService 抓取，經 C 回調
///   以 JSON 供 Rust（每次呼叫取新鮮 OTP；kind=1 是 Rust 認為需要重新佈建
///   時的重抓）。
/// - 2FA：Rust 的回調參數映射到既有的 TwoFACodeProvider（同一個驗證碼輸入
///   框／方式選擇），回應字串照 isideload 的約定（code:／sms:／devices／abort）。
/// - 成功：Rust 回傳 JSON（姓名／adsid／Xcode token），在這裡組成與 SideSign
///   登入相同的 AuthSession，交回 PaxAuthService 走同一套 Keychain 保存交易。
final class EiliRustAuthService {
    static let shared = EiliRustAuthService()
    private init() {}

    struct LoginResult: Decodable {
        struct Team: Decodable { let name: String; let id: String }
        let first_name: String
        let last_name: String
        let adsid: String
        let token: String
        let token_duration: UInt64
        let teams: [Team]
    }

    enum RustLoginError: LocalizedError {
        case failed(String)
        case badResult(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return "Rust 登入失敗：\(message)"
            case .badResult(let raw): return "Rust 登入結果無法解析：\(raw)"
            }
        }
    }

    // MARK: - Attempt context for the C callbacks

    private final class Attempt {
        let codeProvider: TwoFACodeProvider
        /// (forceReprovision) -> fresh anisette, nil on failure.
        let fetchAnisette: (Bool) async -> SideSign.AnisetteData?
        var lastAnisette: SideSign.AnisetteData?

        init(codeProvider: TwoFACodeProvider,
             fetchAnisette: @escaping (Bool) async -> SideSign.AnisetteData?) {
            self.codeProvider = codeProvider
            self.fetchAnisette = fetchAnisette
        }
    }

    private static var currentAttempt: Attempt?
    private static let attemptLock = NSLock()

    private static func liveAttempt() -> Attempt? {
        attemptLock.lock()
        defer { attemptLock.unlock() }
        return currentAttempt
    }

    // MARK: - Entry

    /// 在背景執行緒跑完會阻塞在 C 回調上的 Rust 登入，回傳要保存的 AuthSession。
    func login(
        appleID: String,
        password: String,
        xcodeVersion: String,
        codeProvider: TwoFACodeProvider,
        fetchAnisette: @escaping (Bool) async -> SideSign.AnisetteData?
    ) async throws -> SideSign.AuthSession {
        let attempt = Attempt(codeProvider: codeProvider, fetchAnisette: fetchAnisette)
        Self.attemptLock.lock()
        Self.currentAttempt = attempt
        Self.attemptLock.unlock()
        defer {
            Self.attemptLock.lock()
            if Self.currentAttempt === attempt { Self.currentAttempt = nil }
            Self.attemptLock.unlock()
        }

        let androidLabel = EiliRustLoginSettings.androidClientInfo
        codeProvider.log("Rust 登入：安卓標籤 \(androidLabel)")

        let outcome: (Int32, String) = await Task.detached(priority: .userInitiated) {
            Self.runFFI(appleID: appleID, password: password, androidLabel: androidLabel)
        }.value

        guard outcome.0 == 0 else {
            throw RustLoginError.failed(outcome.1)
        }
        guard let data = outcome.1.data(using: .utf8),
              let result = try? JSONDecoder().decode(LoginResult.self, from: data) else {
            throw RustLoginError.badResult(outcome.1)
        }
        guard let anisette = attempt.lastAnisette else {
            throw RustLoginError.badResult("缺少 anisette 快照")
        }
        codeProvider.log("Rust 登入成功：Teams（\(result.teams.count)）")
        let account = SideSign.Account(
            appleID: appleID,
            identifier: result.adsid,
            firstName: result.first_name,
            lastName: result.last_name
        )
        let session = SideSign.Session(
            dsid: result.adsid,
            authToken: result.token,
            anisetteData: anisette,
            xcodeVersion: xcodeVersion,
            creationDate: Date(),
            timeToLive: TimeInterval(result.token_duration)
        )
        return SideSign.AuthSession(account: account, session: session)
    }

    /// The blocking FFI call itself (runs on the detached task above; the
    /// Rust side parks this thread on the C callbacks).
    private static func runFFI(appleID: String, password: String, androidLabel: String) -> (Int32, String) {
        var buffer = [CChar](repeating: 0, count: 65536)
        let rc = apparition_login_with_headers(
            appleID, password, androidLabel,
            eili_rust_headers, eili_rust_two_factor,
            &buffer, buffer.count
        )
        return (rc, String(cString: buffer))
    }

    // MARK: - Callback plumbing (used by the @_cdecl shims below)

    fileprivate static func headersJSON(kind: Int32) -> String? {
        guard let attempt = liveAttempt() else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var payload: String?
        Task {
            if let data = await attempt.fetchAnisette(kind == 1) {
                attempt.lastAnisette = data
                let dict: [String: Any] = [
                    "machine_id": data.machineID,
                    "one_time_password": data.oneTimePassword,
                    "routing_info": UInt64(data.routingInfo) ?? 17106176,
                    "device_id": data.deviceID,
                    "local_user_id": data.localUserID,
                ]
                if let json = try? JSONSerialization.data(withJSONObject: dict),
                   let string = String(data: json, encoding: .utf8) {
                    payload = string
                }
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if attempt.codeProvider.isCancelled { return nil }
        }
        return payload
    }

    fileprivate static func twoFactorResponse(paramsJSON: String) -> String {
        guard let attempt = liveAttempt(),
              let params = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [String: Any] else {
            return "abort"
        }
        let unknown = (params["unknown"] as? Bool) ?? false
        let sms = (params["sms"] as? Bool) ?? false
        let lastError = params["last_error"] as? String

        let semaphore = DispatchSemaphore(value: 0)
        var response = "abort"
        Task {
            do {
                if unknown {
                    // Rust 還沒決定發送方式：交給既有的方式選擇 UI。
                    let numbers = (params["numbers"] as? [[String: Any]] ?? []).map { entry in
                        TrustedPhoneNumber(
                            id: String((entry["id"] as? NSNumber)?.intValue ?? 1),
                            number: (entry["number_with_dial_code"] as? String) ?? ""
                        )
                    }
                    let method = try await attempt.codeProvider.awaitMethod(
                        phoneNumbers: numbers,
                        preferred: numbers.isEmpty ? .trustedDevice : .sms
                    )
                    switch method {
                    case .trustedDevice: response = "devices"
                    case .sms(let phoneID): response = "sms:\(phoneID)"
                    case .voice(let phoneID): response = "sms:\(phoneID)"
                    }
                } else {
                    let code = try await attempt.codeProvider.awaitCode(
                        mode: sms ? .sms : .trustedDevice,
                        rejected: lastError != nil
                    )
                    response = "code:\(code)"
                }
            } catch {
                response = "abort"
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if attempt.codeProvider.isCancelled { return "abort" }
        }
        return response
    }
}

// MARK: - C callback shims (signatures mirror apparition_anisette.h)

@_cdecl("eili_rust_headers")
func eili_rust_headers(kind: Int32, out: UnsafeMutablePointer<CChar>?, outCap: Int32) -> Int32 {
    guard let out, outCap > 0, let json = EiliRustAuthService.headersJSON(kind: kind) else { return 1 }
    let bytes = Array(json.utf8CString)
    guard bytes.count < Int(outCap) else { return 1 }
    bytes.withUnsafeBufferPointer { src in
        out.update(from: src.baseAddress!, count: src.count)
    }
    out[bytes.count] = 0
    return 0
}

@_cdecl("eili_rust_two_factor")
func eili_rust_two_factor(params: UnsafePointer<CChar>?, out: UnsafeMutablePointer<CChar>?, outCap: Int32) -> Int32 {
    guard let out, outCap > 0 else { return 1 }
    let paramsString = params.map { String(cString: $0) } ?? "{}"
    let response = EiliRustAuthService.twoFactorResponse(paramsJSON: paramsString)
    let bytes = Array(response.utf8CString)
    guard bytes.count < Int(outCap) else { return 1 }
    bytes.withUnsafeBufferPointer { src in
        out.update(from: src.baseAddress!, count: src.count)
    }
    out[bytes.count] = 0
    return 0
}
