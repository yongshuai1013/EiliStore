import Foundation

public enum ProvisioningStorage: Sendable { case memory(existingBlob: Data? = nil) }
public enum FakeAnisetteKitControl {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _calls = 0
    nonisolated(unsafe) private static var _identifier: UUID?
    nonisolated(unsafe) private static var _blob: Data?
    nonisolated(unsafe) private static var _responseBlob: Data? = Data([0xFA, 0xCE])
    nonisolated(unsafe) private static var _throws = false
    nonisolated(unsafe) private static var _delay: UInt64 = 0
    nonisolated(unsafe) private static var _resets = 0
    public static func reset() { lock.lock(); defer { lock.unlock() }; _calls = 0; _identifier = nil; _blob = nil; _responseBlob = Data([0xFA, 0xCE]); _throws = false; _delay = 0 }
    public static func configure(blob: Data?, throwsError: Bool = false, delay: UInt64 = 0) { lock.lock(); defer { lock.unlock() }; _responseBlob = blob; _throws = throwsError; _delay = delay }
    private static func begin(identifier: UUID, blob: Data?) -> (Bool, UInt64, Data?) {
        lock.lock(); defer { lock.unlock() }
        _calls += 1; _identifier = identifier; _blob = blob
        return (_throws, _delay, _responseBlob)
    }
    static func run(identifier: UUID, blob: Data?) async throws -> ([String: String], Data?) {
        let (shouldThrow, delay, result) = begin(identifier: identifier, blob: blob)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if shouldThrow { throw FakeAnisetteError.expected }
        return (Dictionary(uniqueKeysWithValues: ["X-Apple-I-MD-M", "X-Apple-I-MD", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO", "X-Mme-Device-Id", "X-Apple-I-SRL-NO", "X-Mme-Client-Info", "User-Agent", "X-Apple-I-Client-Time", "X-Apple-Locale", "X-Apple-I-TimeZone"].enumerated().map { ($1, "v\($0)") }), result)
    }
    public static var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    public static var identifier: UUID? { lock.lock(); defer { lock.unlock() }; return _identifier }
    public static var blob: Data? { lock.lock(); defer { lock.unlock() }; return _blob }
    public static var resetCount: Int { lock.lock(); defer { lock.unlock() }; return _resets }
    static func didReset() { lock.lock(); defer { lock.unlock() }; _resets += 1 }
}
public enum FakeAnisetteError: Error { case expected }
public enum AnisetteKitLogging { public static func setLogging(_ enabled: Bool) {} }
public struct UnicornAnisetteDataProvider: Sendable { public init() {} }
public final class AnisetteClient: @unchecked Sendable {
    public init(provisioningDir: URL, provider: UnicornAnisetteDataProvider, libraryDirectoryResolver: @escaping @Sendable () throws -> URL) throws {}
    public func getAnisetteData(identifier: UUID, storage: ProvisioningStorage) async throws -> (headers: [String: String], newBlob: Data?) {
        let existing: Data?; if case .memory(let value) = storage { existing = value } else { existing = nil }
        return try await FakeAnisetteKitControl.run(identifier: identifier, blob: existing)
    }
}
public func resetLocalAnisetteEngine() { FakeAnisetteKitControl.didReset() }
