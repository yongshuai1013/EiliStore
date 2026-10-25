import Foundation

@main struct EiliAnisetteRemoteServerSyncTests {
    static func main() throws {
        typealias Sync = EiliAnisetteRemoteServerSync
        typealias Config = EiliAnisetteClientConfiguration

        let serverURL = URL(string: "https://ani.sidestore.zip")!
        let endpoint = try Sync.clientInfoEndpoint(for: serverURL)
        precondition(endpoint.absoluteString == "https://ani.sidestore.zip/v3/client_info")

        for text in ["file:///tmp/server", "https://user@example.com", "https://example.com?token=x", "https://example.com/#fragment"] {
            do {
                _ = try Sync.clientInfoEndpoint(for: URL(string: text)!)
                preconditionFailure("accepted unsafe or malformed server URL: \(text)")
            } catch is Sync.SyncError { }
        }

        let response = #"{"client_info":"<MacBookPro13,3> <Mac OS X>","user_agent":"akd/1.0 CFNetwork/811.5.4","X-Apple-I-MD":"must not become an override"}"#.data(using: .utf8)!
        let headers = try Sync.decodeHeaders(response)
        precondition(headers["client_info"]?.contains("MacBookPro13,3") == true)
        precondition(headers["X-Apple-I-MD"] != nil)

        let initial = Config(clientInfo: "old-client", userAgent: "old-agent",
                             customDeviceID: "550E8400-E29B-41D4-A716-446655440000",
                             customLocalUserID: "local", customSerialNumber: "serial",
                             customRoutingInfo: "123", customLocale: "en-US",
                             customTimeZone: "UTC", customXcodeVersion: "15")
        let updated = try initial.mergingServerHeaders(headers)
        precondition(updated.clientInfo.contains("MacBookPro13,3"))
        precondition(updated.userAgent == "akd/1.0 CFNetwork/811.5.4")
        precondition(updated.customDeviceID == initial.customDeviceID)
        precondition(updated.customLocalUserID == initial.customLocalUserID)
        precondition(updated.customRoutingInfo == initial.customRoutingInfo)

        do {
            _ = try initial.mergingServerHeaders(["client_info": "one", "clientInfo": "two"])
            preconditionFailure("accepted conflicting aliases")
        } catch is Config.ConfigError { }

        for invalid in [Data("[]".utf8), Data(#"{"client_info":1}"#.utf8), Data("not-json".utf8)] {
            do {
                _ = try Sync.decodeHeaders(invalid)
                preconditionFailure("accepted invalid server response")
            } catch is Sync.SyncError { }
        }
        do {
            _ = try Sync.decodeHeaders(Data(repeating: 0x20, count: 65_537))
            preconditionFailure("accepted oversized server response")
        } catch is Sync.SyncError { }

        print("EiliAnisetteRemoteServerSyncTests: PASS")
    }
}
