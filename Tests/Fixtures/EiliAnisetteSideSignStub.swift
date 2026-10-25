import Foundation

public struct AnisetteRequestHeaders: Sendable {
    public var rawHeaders: [String: String]
    public init(rawHeaders: [String: String]) { self.rawHeaders = rawHeaders }
}

public enum AnisetteMode: Sendable, Equatable {
    case remote(server: URL)
    case localODA(libsDir: URL, provisioningDir: URL? = nil)
    case remoteODA(sourceURL: URL, fallbackURL: URL? = nil)
}

public struct AnisetteData: Sendable, Equatable {
    public var machineID, oneTimePassword, localUserID, routingInfo, deviceID, serialNumber, clientInfo, userAgent, clientTime, locale, timeZone: String
    public init(machineID: String, oneTimePassword: String, localUserID: String, routingInfo: String, deviceID: String, serialNumber: String, clientInfo: String, userAgent: String, clientTime: String, locale: String, timeZone: String) {
        self.machineID = machineID; self.oneTimePassword = oneTimePassword; self.localUserID = localUserID; self.routingInfo = routingInfo; self.deviceID = deviceID; self.serialNumber = serialNumber; self.clientInfo = clientInfo; self.userAgent = userAgent; self.clientTime = clientTime; self.locale = locale; self.timeZone = timeZone
    }
}

/// Mirrors the real provider's surface for a -45061 rejection, whose
/// payload the service matches on the error text.
public struct NotProvisionedError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "badServerResponse(statusCode: -1, payload: \"not provisioned for this server (-45061); reprovision required\")" }
}

public actor AnisetteDataManager {
    public static let shared = AnisetteDataManager()
    public var calls = 0
    public var lastServers: [URL] = []
    public var lastIdentifier: UUID?
    public var lastBlob: Data?
    public var lastHeaders: [String: String] = [:]
    public var response: (AnisetteData, Data?)?
    public var delay: UInt64 = 0
    public var active = 0
    public var maxConcurrentForTests = 0
    public var odaCalls = 0
    public var lastMode: AnisetteMode?
    public var lastODAIdentifier: UUID?
    public var lastODABlob: Data?
    public var lastODAHeaders: [String: String] = [:]
    public var odaResponse: (AnisetteData, Data?)?
    public var odaError: Error?
    public var odaDelay: UInt64 = 0
    public var failoverErrorOnce: Error?
    public init() {}
    public func reset() { calls = 0; lastServers = []; lastIdentifier = nil; lastBlob = nil; lastHeaders = [:]; response = nil; delay = 0; active = 0; maxConcurrentForTests = 0; odaCalls = 0; lastMode = nil; lastODAIdentifier = nil; lastODABlob = nil; lastODAHeaders = [:]; odaResponse = nil; odaError = nil; odaDelay = 0; failoverErrorOnce = nil }
    public func setODAResponseForTests(data: AnisetteData?, blob: Data?) { if let data { odaResponse = (data, blob) } else { odaResponse = (AnisetteData(machineID: "m", oneTimePassword: "otp", localUserID: "lu", routingInfo: "r", deviceID: "dev", serialNumber: "s", clientInfo: "ci", userAgent: "ua", clientTime: "t", locale: "en", timeZone: "UTC"), blob) } }
    public func setODAErrorForTests(_ error: Error?) { odaError = error }
    public func setODADelayForTests(_ value: UInt64) { odaDelay = value }
    public func fetchAnisetteData(mode: AnisetteMode? = nil, identifier: UUID, existingAdiBlob: Data? = nil, headers: AnisetteRequestHeaders? = nil, onError: (@Sendable (Error) -> Void)? = nil) async throws -> (AnisetteData, Data?) {
        odaCalls += 1; lastMode = mode; lastODAIdentifier = identifier; lastODABlob = existingAdiBlob
        lastODAHeaders = headers?.rawHeaders ?? [:]
        // Mirror the legacy fake provider: a delay interrupted by cancellation
        // still returns, so the service's save-before-cancellation path runs.
        if odaDelay > 0 { try? await Task.sleep(nanoseconds: odaDelay) }
        if let odaError { throw odaError }
        if let odaResponse { return odaResponse }
        return (AnisetteData(machineID: "m", oneTimePassword: "otp", localUserID: "lu", routingInfo: "r", deviceID: "dev", serialNumber: "s", clientInfo: "ci", userAgent: "ua", clientTime: "t", locale: "en", timeZone: "UTC"), nil)
    }
    public func setDelayForTests(_ value: UInt64) { delay = value }
    public func setResponseForTests(data: AnisetteData?, blob: Data?) { if let data { response = (data, blob) } else { response = (AnisetteData(machineID: "m", oneTimePassword: "otp", localUserID: "lu", routingInfo: "r", deviceID: "dev", serialNumber: "s", clientInfo: "ci", userAgent: "ua", clientTime: "t", locale: "en", timeZone: "UTC"), blob) } }
    public func fetchAnisetteDataWithFailover(servers: [URL], identifier: UUID, existingAdiBlob: Data?, headers: AnisetteRequestHeaders? = nil, onSuccess: (@Sendable (URL) -> Void)? = nil) async throws -> (AnisetteData, Data?) {
        calls += 1; active += 1; maxConcurrentForTests = max(maxConcurrentForTests, active); lastServers = servers; lastIdentifier = identifier; lastBlob = existingAdiBlob
        if let failoverErrorOnce { self.failoverErrorOnce = nil; throw failoverErrorOnce }
        if let first = servers.first { onSuccess?(first) }
        lastHeaders = headers?.rawHeaders ?? [:]
        defer { active -= 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let response { return response }
        return (AnisetteData(machineID: "m", oneTimePassword: "otp", localUserID: "lu", routingInfo: "r", deviceID: "dev", serialNumber: "s", clientInfo: "ci", userAgent: "ua", clientTime: "t", locale: "en", timeZone: "UTC"), nil)
    }
}

extension AnisetteDataManager {
    public func setFailoverErrorOnceForTests(_ error: Error?) { failoverErrorOnce = error }
}
