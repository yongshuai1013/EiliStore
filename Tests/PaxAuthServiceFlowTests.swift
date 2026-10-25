import Foundation
import SideSign

enum EiliAnisetteMode: String { case remote, onDevice; static let preferenceKey = "mode"; static let sessionKey = "session-mode"; static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "remote") ?? .remote } }
struct EiliAnisetteClientConfiguration { func resolvedXcodeVersion() -> String { "test-xcode" } }
actor EiliAnisetteClientConfigurationStore { static let shared = EiliAnisetteClientConfigurationStore(); func load() async throws -> EiliAnisetteClientConfiguration { .init() } }
actor EiliSideSignClientConfigurationStore { static let shared = EiliSideSignClientConfigurationStore(); func makePortal() async throws -> SideSign.DeveloperPortal { .init() } }
enum EiliAnisetteError: Error { case unavailable }
struct AnisetteServer { let name: String; let url: String; var nsURL: URL? { URL(string: url) } }
final class AnisetteServerManager { static let shared = AnisetteServerManager(); var selectedServer: AnisetteServer { AnisetteServer(name: "Test Server", url: "https://example.com") }; var autoRotationEnabled: Bool { false }; func serversForLogin() -> [URL] { [] }; func serverName(for url: URL) -> String? { nil } }
final class EiliAnisetteService {
    static let shared = EiliAnisetteService()
    var calls = 0; var failure = false; var onFetch: (() -> Void)?
    var lastDiagnosticAttempt: UUID?
    var lastRemoteResponderURL: URL?
    func fetch(remoteIdentifier: UUID, remoteBlob: Data?, servers: [URL], mode: EiliAnisetteMode, configuration: EiliAnisetteClientConfiguration, diagnosticAttempt: UUID? = nil) async throws -> SideSign.AnisetteData {
        lastDiagnosticAttempt = diagnosticAttempt
        calls += 1; onFetch?(); if failure { throw EiliAnisetteError.unavailable }; return .init(machineID: "anisette-snapshot")
    }
}
enum KeychainHelper {
    static var data: [String: Data] = [:]
    static var failNextWriteForKey: String?
    static func load(forKey key: String) -> Data? { data[key] }
    static func loadString(forKey key: String) -> String? { data[key].flatMap { String(data: $0, encoding: .utf8) } }
    static func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? { data[key].flatMap { try? JSONDecoder().decode(type, from: $0) } }
    private static func shouldFail(_ key: String) -> Bool { guard failNextWriteForKey == key else { return false }; failNextWriteForKey = nil; return true }
    @discardableResult static func save(_ value: Data, forKey key: String) -> Bool { guard !shouldFail(key) else { return false }; data[key] = value; return true }
    @discardableResult static func saveString(_ value: String, forKey key: String) -> Bool { guard !shouldFail(key) else { return false }; data[key] = Data(value.utf8); return true }
    @discardableResult static func saveCodable<T: Encodable>(_ value: T, forKey key: String) -> Bool { guard !shouldFail(key), let d = try? JSONEncoder().encode(value) else { return false }; data[key] = d; return true }
    @discardableResult static func delete(forKey key: String) -> Bool { data.removeValue(forKey: key) != nil }
}
final class LoginFlowLogFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
#if !LOGIN_HANDLER_TESTS
@main struct PaxAuthServiceFlowTests {
    static let sk = "paxstore.auth.session", ik = "paxstore.auth.appleID"
    static func oldState() throws -> (Data, Data) {
        let s = try JSONEncoder().encode(SideSign.AuthSession(appleID: "old@example.invalid")), i = Data("old@example.invalid".utf8)
        KeychainHelper.data[sk] = s; KeychainHelper.data[ik] = i; UserDefaults.standard.set("old-mode", forKey: EiliAnisetteMode.sessionKey); return (s, i)
    }
    static func unchanged(_ old: (Data, Data)) { assert(KeychainHelper.data[sk] == old.0 && KeychainHelper.data[ik] == old.1); assert(UserDefaults.standard.string(forKey: EiliAnisetteMode.sessionKey) == "old-mode") }
    static func diagnosticOutcome(_ expected: String) {
        let report = EiliLoginDiagnostics.shared.report()
        let current = report.components(separatedBy: "前一次")[0]
        assert(current.contains("最近一次：\(expected)"))
        for sensitive in ["@example.invalid", "123456", "654321", "anisette-snapshot", "sms-id", "voice-id"] {
            assert(!report.contains(sensitive), "diagnostics leaked synthetic input")
        }
    }
    static func main() async throws {
        let service = PaxAuthService.shared
        UserDefaults.standard.set(EiliAnisetteMode.remote.rawValue, forKey: EiliAnisetteMode.preferenceKey)
        KeychainHelper.data.removeAll(); EiliAnisetteService.shared.calls = 0
        let retry = TwoFACodeProvider(), events = LockedValue<[String]>([])
        retry.onCodeRequired = { mode, rejected in events.set(events.get() + ["\(mode):\(rejected)"]); retry.submitCode("123456") }
        SideSign.DeveloperPortal.reset(requests: [.trustedDevice(error: nil), .trustedDevice(error: CocoaError(.fileReadCorruptFile))], result: .success(.init(appleID: "sdk-returned@example.invalid")))
        EiliAnisetteService.shared.onFetch = { UserDefaults.standard.set(EiliAnisetteMode.onDevice.rawValue, forKey: EiliAnisetteMode.preferenceKey) }
        let retryLogin = try await service.login(appleID: "input@example.invalid", password: "unused", codeProvider: retry)
        assert(retryLogin)
        diagnosticOutcome("succeeded")
        assert(EiliAnisetteService.shared.lastDiagnosticAttempt != nil)
        let currentReport = EiliLoginDiagnostics.shared.report().components(separatedBy: "前一次")[0]
        for stage in ["authServiceEntered", "loginStarted", "configurationReady", "sessionSaving"] {
            assert(currentReport.contains(stage), "explicit diagnostic ID lost: \(stage)")
        }
        assert(events.get() == ["trustedDevice:false", "trustedDevice:true"] && SideSign.DeveloperPortal.responses.count == 2)
        assert(SideSign.DeveloperPortal.authCalls == 1 && SideSign.DeveloperPortal.remainingRequests == 0)
        assert(SideSign.DeveloperPortal.observedAnisette?.machineID == "anisette-snapshot" && SideSign.DeveloperPortal.observedXcodeVersion == "test-xcode")
        assert(UserDefaults.standard.string(forKey: EiliAnisetteMode.sessionKey) == EiliAnisetteMode.remote.rawValue)
        assert(service.currentAppleID == "sdk-returned@example.invalid" && KeychainHelper.loadCodable(SideSign.AuthSession.self, forKey: sk)?.account.appleID == "sdk-returned@example.invalid")

        // The production provider selects each delivery method, passes the chosen phone ID, and receives that method's code callback.
        for (selection, method, followup, expectedID, expectedMode) in [
            (VerificationRequest.selectDeliveryMethod(preferredMode: .sms, phoneNumbers: []), TwoFactorMethod.sms(phoneID: "sms-id"), VerificationRequest.sms(phoneID: "sms-id", phoneNumber: "***1", error: nil), "sms-id", TwoFactorDeliveryMode.sms),
            (VerificationRequest.selectDeliveryMethod(preferredMode: .voice, phoneNumbers: []), TwoFactorMethod.voice(phoneID: "voice-id"), VerificationRequest.voice(phoneID: "voice-id", phoneNumber: "***2", error: nil), "voice-id", TwoFactorDeliveryMode.voice)
        ] {
            let p = TwoFACodeProvider(), modes = LockedValue<[String]>([])
            p.onMethodRequired = { _, _ in p.submitMethod(method) }
            p.onCodeRequired = { mode, rejected in modes.set(modes.get() + ["\(mode):\(rejected)"]); p.submitCode("654321") }
            SideSign.DeveloperPortal.reset(requests: [selection, followup], result: .success(.init(appleID: "selected@example.invalid")))
            let prior = SideSign.DeveloperPortal.authCalls
            let selectedLogin = try await service.login(appleID: "input@example.invalid", password: "unused", codeProvider: p)
            assert(selectedLogin)
            assert(SideSign.DeveloperPortal.authCalls == prior + 1 && modes.get() == ["\(expectedMode):false"])
            switch SideSign.DeveloperPortal.responses[0] {
            case .requestSMS(let id), .requestVoice(let id): assert(id == expectedID)
            default: assertionFailure("incorrect selected route")
            }
            if case .verificationCode("654321") = SideSign.DeveloperPortal.responses[1] {} else { assertionFailure("code callback missing") }
        }
        for portalError in [SideSign.DeveloperPortalError.incorrectCredentials, .tooManyAttempts] {
            let old = try oldState(), logged = LoginFlowLogFlag(), p = TwoFACodeProvider()
            p.onCodeRequired = { _, _ in p.submitCode("123456") }; p.onLog = { if $0 == "登入資料已安全保存" { logged.set() } }
            SideSign.DeveloperPortal.reset(result: .failure(portalError)); let before = EiliAnisetteService.shared.calls
            do { _ = try await service.login(appleID: "new@example.invalid", password: "bad", codeProvider: p); fatalError("portal error expected") } catch {}
            unchanged(old); assert(EiliAnisetteService.shared.calls == before + 1 && !logged.get())
            diagnosticOutcome("failed")
        }
        // Cancel from inside the actual pending code callback.
        do {
            let old = try oldState(), logged = LoginFlowLogFlag(), p = TwoFACodeProvider()
            p.onCodeRequired = { _, _ in p.cancel() }; p.onLog = { if $0 == "登入資料已安全保存" { logged.set() } }
            SideSign.DeveloperPortal.reset(requests: [.sms(phoneID: "p", phoneNumber: "***", error: nil)])
            do { _ = try await service.login(appleID: "new@example.invalid", password: "p", codeProvider: p); fatalError("cancel expected") } catch {}
            unchanged(old); assert(!logged.get() && SideSign.DeveloperPortal.responses.isEmpty)
            diagnosticOutcome("cancelled")
        }
        // Fake authenticate hook cancels before portal completion; production's post-auth cancellation guard must preserve prior state.
        do {
            let old = try oldState(), logged = LoginFlowLogFlag(), p = TwoFACodeProvider()
            p.onCodeRequired = { _, _ in p.submitCode("123456") }; p.onLog = { if $0 == "登入資料已安全保存" { logged.set() } }
            SideSign.DeveloperPortal.reset(result: .success(.init(appleID: "must-not-save@example.invalid")), onAuthenticate: { p.cancel() })
            do { _ = try await service.login(appleID: "new@example.invalid", password: "p", codeProvider: p); fatalError("post-portal cancel expected") } catch {}
            unchanged(old); assert(!logged.get())
            diagnosticOutcome("cancelled")
        }
        // Keep both transactional-write failure cases.
        for failed in [sk, ik] {
            let old = try oldState(); KeychainHelper.failNextWriteForKey = failed
            let logged = LoginFlowLogFlag(), p = TwoFACodeProvider(); p.onCodeRequired = { _, _ in p.submitCode("123456") }; p.onLog = { if $0 == "登入資料已安全保存" { logged.set() } }
            SideSign.DeveloperPortal.reset(result: .success(.init(appleID: "new@example.invalid")))
            do { _ = try await service.login(appleID: "new@example.invalid", password: "p", codeProvider: p); fatalError("save failure expected") } catch {}
            unchanged(old); assert(!logged.get())
            diagnosticOutcome("failed")
        }
        let old = try oldState(), calls = SideSign.DeveloperPortal.authCalls
        EiliAnisetteService.shared.failure = true
        do { _ = try await service.login(appleID: "new@example.invalid", password: "p"); fatalError("fetch failure expected") } catch {}
        assert(SideSign.DeveloperPortal.authCalls == calls); unchanged(old)
        diagnosticOutcome("failed")
        print("PaxAuthServiceFlowTests: PASS (offline fake SDK; no Apple login/network)")
    }
}
#endif
