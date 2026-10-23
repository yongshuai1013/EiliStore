import Foundation

public enum AnisetteProviderStage: String, Sendable {
    case headersStarted, headersReturned
    case provisionStartStarted, provisionStartReturned
    case provisionEndStarted, provisionEndReturned
}

public struct AnisetteProviderDiagnostic: Sendable {
    public enum Operation: String, Sendable { case headers, provisionStart, provisionEnd }
    public enum Result: String, Sendable { case boundaryReturned, parsed, nilResponse, invalidJSON, invalidResponse, providerError }
    public enum Phase: String, Sendable { case loadLibrary }
    public let operation: Operation
    public let result: Result
    public let phase: Phase?
    public let code: Int32
    public let nativeCode: Int32?
}

public struct AnisetteRequestHeaders: Sendable {
    public var rawHeaders: [String: String]
    public init(rawHeaders: [String: String]) { self.rawHeaders = rawHeaders }
}

public enum ProvisioningStorage: Sendable { case memory(existingBlob: Data? = nil) }
public enum FakeAnisetteKitControl {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _calls = 0
    nonisolated(unsafe) private static var _identifier: UUID?
    nonisolated(unsafe) private static var _blob: Data?
    nonisolated(unsafe) private static var _headers: [String: String] = [:]
    nonisolated(unsafe) private static var _responseBlob: Data? = Data([0xFA, 0xCE])
    nonisolated(unsafe) private static var _throws = false
    nonisolated(unsafe) private static var _delay: UInt64 = 0
    nonisolated(unsafe) private static var _resets = 0
    nonisolated(unsafe) private static var _initializations = 0
    nonisolated(unsafe) private static var _routingInfo = "v3"
    public static func reset() { lock.lock(); defer { lock.unlock() }; _calls = 0; _identifier = nil; _blob = nil; _headers = [:]; _responseBlob = Data([0xFA, 0xCE]); _throws = false; _delay = 0; _initializations = 0; _routingInfo = "v3" }
    public static func configure(blob: Data?, throwsError: Bool = false, delay: UInt64 = 0, routingInfo: String = "v3") { lock.lock(); defer { lock.unlock() }; _responseBlob = blob; _throws = throwsError; _delay = delay; _routingInfo = routingInfo }
    private static func begin(identifier: UUID, blob: Data?, headers: [String: String]) -> (Bool, UInt64, Data?, String) {
        lock.lock(); defer { lock.unlock() }
        _calls += 1; _identifier = identifier; _blob = blob
        _headers = headers
        return (_throws, _delay, _responseBlob, _routingInfo)
    }
    static func run(identifier: UUID, blob: Data?, headers: [String: String]) async throws -> ([String: String], Data?) {
        let (shouldThrow, delay, result, routingInfo) = begin(identifier: identifier, blob: blob, headers: headers)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if shouldThrow { throw FakeAnisetteError.expected }
        var response = Dictionary(uniqueKeysWithValues: ["X-Apple-I-MD-M", "X-Apple-I-MD", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO", "X-Mme-Device-Id", "X-Apple-I-SRL-NO", "X-Mme-Client-Info", "User-Agent", "X-Apple-I-Client-Time", "X-Apple-Locale", "X-Apple-I-TimeZone"].enumerated().map { ($1, "v\($0)") })
        response["x-apple-i-md-rinfo"] = routingInfo
        response.removeValue(forKey: "X-Apple-I-MD-RINFO")
        return (response, result)
    }
    public static var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    public static var identifier: UUID? { lock.lock(); defer { lock.unlock() }; return _identifier }
    public static var blob: Data? { lock.lock(); defer { lock.unlock() }; return _blob }
    public static var headers: [String: String] { lock.lock(); defer { lock.unlock() }; return _headers }
    public static var resetCount: Int { lock.lock(); defer { lock.unlock() }; return _resets }
    public static var initializations: Int { lock.lock(); defer { lock.unlock() }; return _initializations }
    static func didInitialize() { lock.lock(); defer { lock.unlock() }; _initializations += 1 }
    static func didReset() { lock.lock(); defer { lock.unlock() }; _resets += 1 }
    static var throwsError: Bool { lock.lock(); defer { lock.unlock() }; return _throws }
}
public enum FakeAnisetteError: Error { case expected }
public enum AnisetteKitLogging { public static func setLogging(_ enabled: Bool) {} }
public struct UnicornAnisetteDataProvider: Sendable {
    let onStage: (@Sendable (AnisetteProviderStage) -> Void)?
    let onDiagnostic: (@Sendable (AnisetteProviderDiagnostic) -> Void)?
    public init(onStage: (@Sendable (AnisetteProviderStage) -> Void)? = nil,
                onDiagnostic: (@Sendable (AnisetteProviderDiagnostic) -> Void)? = nil) {
        self.onStage = onStage
        self.onDiagnostic = onDiagnostic
    }
}
public final class AnisetteClient: @unchecked Sendable {
    private let provider: UnicornAnisetteDataProvider
    public init(provisioningDir: URL, requiredLibraries: [String] = [], provider: UnicornAnisetteDataProvider, libraryDirectoryResolver: @escaping @Sendable () throws -> URL) throws { self.provider = provider; FakeAnisetteKitControl.didInitialize() }
    public func getAnisetteData(identifier: UUID, storage: ProvisioningStorage, headers: AnisetteRequestHeaders? = nil) async throws -> (headers: [String: String], newBlob: Data?) {
        let existing: Data?; if case .memory(let value) = storage { existing = value } else { existing = nil }
        provider.onStage?(.headersStarted)
        provider.onStage?(.headersReturned)
        provider.onStage?(.provisionStartStarted)
        if FakeAnisetteKitControl.throwsError {
            provider.onDiagnostic?(.init(operation: .provisionStart, result: .boundaryReturned, phase: nil, code: -2, nativeCode: nil))
            provider.onDiagnostic?(.init(operation: .provisionStart, result: .providerError, phase: .loadLibrary, code: -2, nativeCode: -42))
            return try await FakeAnisetteKitControl.run(identifier: identifier, blob: existing, headers: headers?.rawHeaders ?? [:])
        }
        provider.onDiagnostic?(.init(operation: .provisionStart, result: .boundaryReturned, phase: nil, code: 0, nativeCode: nil))
        provider.onDiagnostic?(.init(operation: .provisionStart, result: .parsed, phase: nil, code: 0, nativeCode: nil))
        provider.onStage?(.provisionStartReturned)
        provider.onStage?(.provisionEndStarted)
        provider.onStage?(.provisionEndReturned)
        return try await FakeAnisetteKitControl.run(identifier: identifier, blob: existing, headers: headers?.rawHeaders ?? [:])
    }
}
public func resetLocalAnisetteEngine() { FakeAnisetteKitControl.didReset() }
