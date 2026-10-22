import Foundation

@main struct EiliAnisetteClientConfigurationTests {
    static func main() async throws {
        typealias C = EiliAnisetteClientConfiguration
        let full = C(clientInfo: "c", userAgent: "u", customDeviceID: "550E8400-E29B-41D4-A716-446655440000", customLocalUserID: "l", customSerialNumber: "s", customRoutingInfo: "123", customLocale: "en-US", customTimeZone: "UTC", customXcodeVersion: "15")
        let json = try full.encodedJSON()
        let roundtrip = try C.decodeJSON(json)
        precondition(roundtrip == full)
        let aliases = #"{"client_info":"c","User-Agent":"u","custom_device_id":"550E8400-E29B-41D4-A716-446655440000","local_user_id":"l","serial_number":"s","routing_info":"123","locale":"en-US","time_zone":"UTC","xcode_version":"15"}"#.data(using: .utf8)!
        let aliased = try C.decodeJSON(aliases)
        precondition(aliased == full)
        let headerAliases = #"{"X-Mme-Client-Info":"c","User-Agent":"u","deviceUniqueIdentifier":"550E8400-E29B-41D4-A716-446655440000","X-Apple-I-MD-LU":"l","X-Apple-I-SRL-NO":"s","X-Apple-I-MD-RINFO":"123","X-Apple-Locale":"en-US","X-Apple-I-TimeZone":"UTC","X-Xcode-Version":"15"}"#.data(using: .utf8)!
        let headerAliased = try C.decodeJSON(headerAliases)
        precondition(headerAliased == full)
        let secretHeaders = ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-MD", "X-Apple-I-MD-RINFO-SECRET"]
        for key in secretHeaders { do { _ = try C.decodeJSON(Data(("{\"" + key + "\":\"secret\"}").utf8)); preconditionFailure("accepted secret header: \(key)") } catch is C.ConfigError {} }
        let empty = try C.decodeJSON(Data("{}".utf8))
        precondition(empty == .empty)
        let invalid = [#"{"userAgent":1}"#, #"{"userAgent":null}"#, #"{"extra":"x"}"#, #"{"machineID":"x"}"#, #"{"OTP":"x"}"#, #"{"adiBlob":"x"}"#, #"{"session":"x"}"#, #"{"userAgent":"a","User-Agent":"b"}"#, "{\"userAgent\":\"a\\r\\nb\"}", #"{"customDeviceID":"not-uuid"}"#, #"{"customRoutingInfo":"-1"}"#, #"{"customRoutingInfo":"18446744073709551616"}"#, #"{"customTimeZone":"No/Such_Zone"}"#]
        for item in invalid { do { _ = try C.decodeJSON(Data(item.utf8)); preconditionFailure("accepted invalid input") } catch is C.ConfigError {} }
        do { _ = try C.decodeJSON(Data(("{\"customLocale\":\"" + String(repeating: "a", count: 4097) + "\"}").utf8)); preconditionFailure("accepted oversize field") } catch is C.ConfigError {}
        do { _ = try C.decodeJSON(Data(repeating: 0x20, count: 65_537)); preconditionFailure("accepted oversize JSON") } catch is C.ConfigError {}
        do { _ = try C.decodeJSON(Data(#"{"userAgent":"x\u0001y"}"#.utf8)); preconditionFailure("accepted control") } catch is C.ConfigError {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("overrides.json")
        let store = EiliAnisetteClientConfigurationStore(fileURL: file)
        let initial = try await store.load(); precondition(initial == .empty)
        try await store.save(full)
        let loaded = try await store.load(); precondition(loaded == full)
        do { try await store.save(C(customRoutingInfo: "invalid")); preconditionFailure("invalid save succeeded") } catch is C.ConfigError {}
        let retained = try await store.load(); precondition(retained == full)
        try await store.reset()
        let reset = try await store.load(); precondition(reset == .empty)
        try? FileManager.default.removeItem(at: directory)
        print("EiliAnisetteClientConfigurationTests: PASS")
    }
}
