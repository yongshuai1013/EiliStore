import Foundation

@_silgen_name("transport_reset") private func transportReset()
@_silgen_name("transport_set_mode") private func transportSetMode(_ mode: Int32)
@_silgen_name("transport_count") private func transportCount(_ index: Int32) -> Int32

@main
struct RustDeviceTransportTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RustDeviceTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        func plist(_ object: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        }
        let remoteBytes = try plist(["public_key": Data(repeating: 0x31, count: 32), "private_key": Data(repeating: 0x52, count: 32), "identifier": "SYNTHETIC_REMOTE_IDENTIFIER"])
        let lockdownBytes = try plist(["HostID": "synthetic-host", "SystemBUID": "synthetic-buid", "HostPrivateKey": Data([1]), "HostCertificate": Data([2]), "RootCertificate": Data([3]), "DeviceCertificate": Data([4])])
        func makeStore(_ name: String, bytes: Data, type: PairingType) throws -> (URL, PairingFileStore) {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(type.fileName)
            try bytes.write(to: url)
            let suite = "RustDeviceTransportTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return (url, PairingFileStore(directory: dir, defaults: defaults))
        }
        func count(_ index: Int32) -> Int { Int(transportCount(index)) }
        let remote = try makeStore("remote", bytes: remoteBytes, type: .remote)
        let lockdown = try makeStore("lockdown", bytes: lockdownBytes, type: .lockdown)
        let services: [RustDeviceTransport.Service] = [.afc, .installationProxy, .misagent, .heartbeat, .lockdown]
        let priorRemotePort = UserDefaults.standard.object(forKey: "pairing.remotePort")
        defer {
            if let priorRemotePort { UserDefaults.standard.set(priorRemotePort, forKey: "pairing.remotePort") }
            else { UserDefaults.standard.removeObject(forKey: "pairing.remotePort") }
        }
        if ProcessInfo.processInfo.environment["TEST_LOGGER_FAILURE"] == "1" {
            transportReset()
            for _ in 0..<2 {
                do { _ = try RustDeviceTransport(store: remote.1).connect(.afc, host: "127.0.0.1", pairingFileURL: remote.0); fatalError("FAIL: logger initialization failure ignored") }
                catch { check(!(error.localizedDescription.contains("SYNTHETIC_RUST_ERROR_SENTINEL")), "logger failure is generic") }
            }
            check(count(14) == 1 && count(0) == 0 && count(4) == 0, "logger failure is cached once and gates all device FFI")
            print("PASS: RustDeviceTransport cached logger failure")
            return
        }

        // Every service uses its matching RSD connector; the remote pairing call is verify-only.
        transportReset()
        UserDefaults.standard.set(54321, forKey: "pairing.remotePort")
        for (index, service) in services.enumerated() {
            let transport = RustDeviceTransport(store: remote.1)
            _ = try transport.connect(service, host: "127.0.0.1", pairingFileURL: remote.0)
            check(count(Int32(20 + index)) == 1, "Remote service \(index) calls its RSD connector")
            check(count(Int32(30 + index)) == 0, "Remote service \(index) avoids ordinary connector")
            transport.disconnect()
        }
        check(count(0) == 5 && count(2) == 5, "Remote pairing handle freed once per connection")
        check(count(4) == 5 && count(6) == 0 && count(12) == 0, "tunnel always disables first-time pair setup")
        check(count(13) == 54321, "configured Remote port reaches tunnel sockaddr")
        check(count(15) == 0 && count(16) == 0, "Remote tunnel has no PIN callback or context")
        check(count(14) == 1, "Rust logger is configured exactly once process-wide")
        check(count(7) == 5 && count(8) == 5 && count(9) == 5, "each tunnel adapter is closed/freed and handshake freed")
        UserDefaults.standard.removeObject(forKey: "pairing.remotePort")

        // Lockdown uses provider-based APIs and transfers the pairing handle on success.
        transportReset()
        let lockdownTransport = RustDeviceTransport(store: lockdown.1)
        _ = try lockdownTransport.connect(.lockdown, host: "127.0.0.1", pairingFileURL: lockdown.0)
        check(count(1) == 1 && count(3) == 0, "Lockdown pairing handle ownership transfers on success")
        check(count(5) == 1 && count(34) == 1 && count(24) == 0, "Lockdown service uses provider connector only")
        lockdownTransport.disconnect()
        check(count(10) == 1, "Lockdown provider released on disconnect")

        // Missing and structurally invalid records stop before parser or transport FFI.
        transportReset()
        let missing = root.appendingPathComponent("missing.plist")
        do { _ = try RustDeviceTransport(store: remote.1).connect(.afc, host: "127.0.0.1", pairingFileURL: missing); fatalError("FAIL: missing file accepted") }
        catch { }
        let malformed = root.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        let malformedURL = malformed.appendingPathComponent(PairingType.remote.fileName)
        try Data("not a plist".utf8).write(to: malformedURL)
        let suite = "RustDeviceTransportTests.\(UUID().uuidString)"
        let invalidStore = PairingFileStore(directory: malformed, defaults: UserDefaults(suiteName: suite)!)
        do { _ = try RustDeviceTransport(store: invalidStore).connect(.afc, host: "127.0.0.1", pairingFileURL: malformedURL); fatalError("FAIL: invalid record accepted") }
        catch { }
        check(count(0) == 0 && count(1) == 0 && count(4) == 0 && count(5) == 0, "missing or invalid files invoke no FFI")

        // Parser, tunnel, provider, and service errors cannot expose the Rust sentinel; cleanup is balanced.
        transportReset(); transportSetMode(1)
        do { _ = try RustDeviceTransport(store: remote.1).connect(.afc, host: "127.0.0.1", pairingFileURL: remote.0); fatalError("FAIL: parser error ignored") }
        catch { check(!error.localizedDescription.contains("SYNTHETIC_RUST_ERROR_SENTINEL"), "parser error sanitized") }
        check(count(11) == 1 && count(4) == 0 && count(2) == 0, "parser error freed and no tunnel/free of absent pairing handle")

        transportReset(); transportSetMode(2)
        do { _ = try RustDeviceTransport(store: remote.1).connect(.afc, host: "127.0.0.1", pairingFileURL: remote.0); fatalError("FAIL: tunnel error ignored") }
        catch { check(!error.localizedDescription.contains("SYNTHETIC_RUST_ERROR_SENTINEL"), "tunnel error sanitized") }
        check(count(11) == 1 && count(2) == 1 && count(7) == 0 && count(8) == 0 && count(9) == 0, "tunnel failure frees error and pairing, no absent handles")

        transportReset(); transportSetMode(3)
        do { _ = try RustDeviceTransport(store: remote.1).connect(.afc, host: "127.0.0.1", pairingFileURL: remote.0); fatalError("FAIL: service error ignored") }
        catch { check(!error.localizedDescription.contains("SYNTHETIC_RUST_ERROR_SENTINEL"), "service error sanitized") }
        check(count(11) == 1 && count(2) == 1 && count(7) == 1 && count(8) == 1 && count(9) == 1, "service error frees error plus adapter/handshake/pairing")

        transportReset(); transportSetMode(4)
        do { _ = try RustDeviceTransport(store: lockdown.1).connect(.afc, host: "127.0.0.1", pairingFileURL: lockdown.0); fatalError("FAIL: provider error ignored") }
        catch { check(!error.localizedDescription.contains("SYNTHETIC_RUST_ERROR_SENTINEL"), "provider error sanitized") }
        check(count(11) == 1 && count(3) == 1 && count(10) == 0, "provider error frees unconsumed pairing exactly once")

        transportReset()
        print("PASS: RustDeviceTransport synthetic FFI integration tests")
    }
}
