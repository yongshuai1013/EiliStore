import Foundation
import SideSign

@main struct Tests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("invalid configuration was accepted") } catch {}
    }

    static func main() async throws {
        let config = try EiliSideSignClientConfiguration.decodeJSON(Data(#"{"grandSlam":{"service":"  service-v2  ","headerVersion":"v9"},"appleAuth":{"userAgent":"agent"},"developerServices":{"clientID":"client"}}"#.utf8))
        check(config.grandSlam.service == "service-v2", "trim")
        let roundTrip = try EiliSideSignClientConfiguration.decodeJSON(config.encodedJSON())
        check(roundTrip == config, "round trip")
        let headers = try config.resolvedHeaders()
        check(headers.grandSlam.service == "service-v2" && headers.grandSlam.authApp == "default-app" && headers.developerServices.protocolVersion == "default-pv", "default/header mapping")
        check(headers.grandSlam.clientInfo == "default-client-info" && headers.grandSlam.xcodeVersion == "default-xcode-version" && headers.grandSlam.phoneClientInfo == "default-phone-client-info", "identity header defaults")
        let all = EiliSideSignClientConfiguration(
            grandSlam: .init(service: "svc", headerVersion: "2", authApp: "auth", userAgent: "gs agent", clientInfo: "gs client info", xcodeVersion: "14.2 (14C18)", phoneClientInfo: "gs phone info"),
            appleAuth: .init(appIDKey: "appid", userAgent: "aa agent"),
            developerServices: .init(clientID: "client-id", protocolVersion: "v1", servicesProtocolVersion: "v2", userAgent: "ds agent"))
        let allHeaders = try all.resolvedHeaders()
        check(allHeaders.grandSlam == .init(service: "svc", headerVersion: "2", authApp: "auth", userAgent: "gs agent", clientInfo: "gs client info", xcodeVersion: "14.2 (14C18)", phoneClientInfo: "gs phone info"), "all GrandSlam fields")
        check(allHeaders.appleAuth == .init(appIDKey: "appid", userAgent: "aa agent"), "all AppleAuth fields")
        check(allHeaders.developerServices == .init(clientID: "client-id", protocolVersion: "v1", servicesProtocolVersion: "v2", userAgent: "ds agent"), "all DeveloperServices fields")
        check(try EiliSideSignClientConfiguration.decodeJSON(all.encodedJSON()) == all, "all-field JSON round trip")

        for json in [#"{"other":{}}"#, #"{"grandSlam":{"password":"x"}}"#,
                     #"{"appleAuth":{"appIDKey":4}}"#, #"{"grandSlam":[]}"#,
                     #"{"developerServices":{"clientID":null}}"#, #"{"token":"x"}"#,
                     #"{"grandSlam":{"User-Agent":"x"}}"#, #"[]"#, #"false"#] {
            rejects { _ = try EiliSideSignClientConfiguration.decodeJSON(Data(json.utf8)) }
        }
        rejects { _ = try EiliSideSignClientConfiguration.decodeJSON(Data(repeating: 0x20, count: 65_537)) }
        for value in ["x\r\ny", "bad\u{0}value", "\tvalue", "é", String(repeating: "a", count: 4097)] {
            rejects { _ = try EiliSideSignClientConfiguration(grandSlam: .init(service: value)).validated() }
        }
        rejects { _ = try EiliSideSignClientConfiguration(grandSlam: .init(headerVersion: "v 1")).validated() }
        for item in [EiliSideSignClientConfiguration(grandSlam: .init(userAgent: "é")),
                     EiliSideSignClientConfiguration(appleAuth: .init(userAgent: "é")),
                     EiliSideSignClientConfiguration(developerServices: .init(userAgent: "é"))] {
            rejects { _ = try item.validated() }
        }
        _ = try EiliSideSignClientConfiguration(grandSlam: .init(service: "hello world", userAgent: "hello world")).validated()
        _ = try EiliSideSignClientConfiguration(grandSlam: .init(xcodeVersion: "14.2 (14C18)", clientInfo: "<Windows> <Windows;10.0.19045>", phoneClientInfo: "<Mac15,7> <macOS;27.0>")).validated()
        for item in [EiliSideSignClientConfiguration(grandSlam: .init(clientInfo: "é")),
                     EiliSideSignClientConfiguration(grandSlam: .init(phoneClientInfo: "é"))] {
            rejects { _ = try item.validated() }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sidesign-overrides.json")
        let store = EiliSideSignClientConfigurationStore(fileURL: url)
        check(try await store.load() == .empty, "missing is empty")
        try await store.save(config)
        check(try await store.load() == config, "save/load")
        let before = try Data(contentsOf: url)
        do { try await store.save(.init(grandSlam: .init(service: "bad\nvalue"))); fatalError("invalid save") } catch {}
        check(try Data(contentsOf: url) == before, "failed save preserves old value")
        let portal = try await store.makePortal()
        check(portal.customHeaders == headers, "portal snapshots custom headers")
        try await store.save(all)
        let second = try await store.makePortal()
        check(portal !== second && portal.customHeaders == headers && second.customHeaders == allHeaders,
              "new config mutated a portal already in use")
        try await store.reset()
        check(try await store.load() == .empty, "reset")
        let resetPortal = try await store.makePortal()
        check(resetPortal.customHeaders == SideSignHeaders(), "reset failed to restore native defaults")
        check(portal.customHeaders == headers && second.customHeaders == allHeaders, "reset mutated existing snapshots")
        try Data(repeating: 0x20, count: 65_537).write(to: url)
        do { _ = try await store.load(); fatalError("oversized file loaded") } catch {}
        try await store.reset()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do { _ = try await store.load(); fatalError("directory loaded") } catch {}
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("target.json")
        try config.encodedJSON().write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        do { _ = try await store.load(); fatalError("symlink loaded") } catch {}
        print("EiliSideSignClientConfigurationTests: PASS (thirteen-field mapping, schema, round-trip, defaults, validation, bounded storage, preservation, portal snapshots and reset isolation)")
    }
}
