import Foundation

public struct AnisetteData: Sendable, Equatable {
    public var machineID: String
    public var oneTimePassword: String
    public var routingInfo: String
    public init(machineID: String = "test-machine", oneTimePassword: String = "test-otp", routingInfo: String = "17106176") {
        self.machineID = machineID
        self.oneTimePassword = oneTimePassword
        self.routingInfo = routingInfo
    }
}
public struct TrustedPhoneNumber: Sendable { public init() {} }
public enum TwoFactorDeliveryMode: Sendable { case sms, voice, trustedDevice }
public struct Account: Codable, Sendable { public var appleID: String; public var identifier: String; public init(appleID: String) { self.appleID = appleID; self.identifier = appleID } }
public struct AuthSession: Codable, Sendable { public var account: Account; public init(appleID: String) { account = Account(appleID: appleID) } }
public enum VerificationRequest: Sendable {
    case trustedDevice(error: Error?)
    case sms(phoneID: String, phoneNumber: String, error: Error?)
    case voice(phoneID: String, phoneNumber: String, error: Error?)
    case selectDeliveryMethod(preferredMode: TwoFactorDeliveryMode, phoneNumbers: [TrustedPhoneNumber])
}
public enum VerificationResponse: Sendable {
    case verificationCode(String), requestTrustedDevice, requestSMS(phoneID: String), requestVoice(phoneID: String)
}
public enum DeveloperPortalError: Error { case userCancelled, tooManyAttempts, incorrectCredentials, rejected }
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<T>(_ body: (Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(value) }
    func update<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
public struct DeveloperPortal: Sendable {
    public typealias VerificationHandler = @Sendable (VerificationRequest) async throws -> VerificationResponse
    private struct State {
        var requests: [VerificationRequest] = []
        var responses: [VerificationResponse] = []
        var authCalls = 0
        var observedAnisette: AnisetteData?
        var observedXcodeVersion: String?
        var result: Result<AuthSession, DeveloperPortalError> = .success(AuthSession(appleID: "user@example.invalid"))
        var onAuthenticate: (@Sendable () -> Void)?
    }
    private static let state = Locked(State())
    public init() {}
    public static func reset(requests: [VerificationRequest] = [], result: Result<AuthSession, DeveloperPortalError> = .success(AuthSession(appleID: "user@example.invalid")), onAuthenticate: (@Sendable () -> Void)? = nil) {
        state.update { $0 = State(requests: requests, result: result, onAuthenticate: onAuthenticate) }
    }
    public static var authCalls: Int { state.read { $0.authCalls } }
    public static var observedAnisette: AnisetteData? { state.read { $0.observedAnisette } }
    public static var observedXcodeVersion: String? { state.read { $0.observedXcodeVersion } }
    public static var responses: [VerificationResponse] { state.read { $0.responses } }
    public static var remainingRequests: Int { state.read { $0.requests.count } }
    public func authenticate(appleID: String, password: String, anisetteData: AnisetteData, xcodeVersion: String, verificationHandler: @escaping VerificationHandler) async throws -> AuthSession {
        let (requests, callback) = Self.state.update { state -> ([VerificationRequest], (@Sendable () -> Void)?) in
            state.authCalls += 1
            state.observedAnisette = anisetteData
            state.observedXcodeVersion = xcodeVersion
            let requests = state.requests
            state.requests.removeAll()
            return (requests, state.onAuthenticate)
        }
        callback?()
        for request in requests {
            let response = try await verificationHandler(request)
            Self.state.update { $0.responses.append(response) }
        }
        return try Self.state.read { $0.result }.get()
    }
}
