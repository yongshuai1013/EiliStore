import Foundation

public struct AnisetteData: Sendable, Equatable {
    public var machineID, oneTimePassword, localUserID, routingInfo, deviceID, serialNumber, clientInfo, userAgent, clientTime, locale, timeZone: String
    public init(machineID: String, oneTimePassword: String, localUserID: String, routingInfo: String, deviceID: String, serialNumber: String, clientInfo: String, userAgent: String, clientTime: String, locale: String, timeZone: String) {
        self.machineID = machineID; self.oneTimePassword = oneTimePassword; self.localUserID = localUserID; self.routingInfo = routingInfo; self.deviceID = deviceID; self.serialNumber = serialNumber; self.clientInfo = clientInfo; self.userAgent = userAgent; self.clientTime = clientTime; self.locale = locale; self.timeZone = timeZone
    }
}

public actor AnisetteDataManager {
    public static let shared = AnisetteDataManager()
    public var calls = 0
    public var lastServers: [URL] = []
    public var lastIdentifier: UUID?
    public var lastBlob: Data?
    public var response: (AnisetteData, Data?)?
    public var delay: UInt64 = 0
    public var active = 0
    public var maxConcurrentForTests = 0
    public init() {}
    public func reset() { calls = 0; lastServers = []; lastIdentifier = nil; lastBlob = nil; response = nil; delay = 0; active = 0; maxConcurrentForTests = 0 }
    public func setDelayForTests(_ value: UInt64) { delay = value }
    public func setResponseForTests(data: AnisetteData?, blob: Data?) { if let data { response = (data, blob) } else { response = (AnisetteData(machineID: "m", oneTimePassword: "otp", localUserID: "lu", routingInfo: "r", deviceID: "dev", serialNumber: "s", clientInfo: "ci", userAgent: "ua", clientTime: "t", locale: "en", timeZone: "UTC"), blob) } }
    public func fetchAnisetteDataWithFailover(servers: [URL], identifier: UUID, existingAdiBlob: Data?) async throws -> (AnisetteData, Data?) {
        calls += 1; active += 1; maxConcurrentForTests = max(maxConcurrentForTests, active); lastServers = servers; lastIdentifier = identifier; lastBlob = existingAdiBlob
        defer { active -= 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let response { return response }
        return (AnisetteData(machineID: "m", oneTimePassword: "otp", localUserID: "lu", routingInfo: "r", deviceID: "dev", serialNumber: "s", clientInfo: "ci", userAgent: "ua", clientTime: "t", locale: "en", timeZone: "UTC"), nil)
    }
}
