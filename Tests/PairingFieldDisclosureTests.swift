import Foundation

@main
struct PairingFieldDisclosureTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PairingDisclosureTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "PairingDisclosureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = root.appendingPathComponent("records", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PairingFileStore(directory: directory, defaults: defaults)
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
        }
        func rejected(_ operation: () throws -> String) {
            do { _ = try operation(); fatalError("FAIL: unsafe field accepted") }
            catch PairingStoreError.sensitiveFieldUnavailable { }
            catch { fatalError("FAIL: unredacted error type") }
        }
        func encoded(_ dictionary: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
        }
        let lockdown: [String: Any] = [
            "HostID": "synthetic-host", "SystemBUID": "synthetic-system",
            "HostPrivateKey": Data("synthetic-private-key".utf8),
            "HostCertificate": "synthetic-certificate", "RootCertificate": Data([1, 2, 3]),
            "DeviceCertificate": Data([4, 5, 6]), "EscrowBag": Data([0, 255, 1]),
            "UDID": "synthetic-device", "NotAllowed": "synthetic-not-allowed"
        ]
        let canonical = directory.appendingPathComponent(PairingType.lockdown.fileName)
        let original = try encoded(lockdown)
        try original.write(to: canonical)
        check(store.inventory().first?.presentSensitiveFields.contains("HostID") == true, "inventory includes field name")
        let host = try store.loadSensitiveField("HostID", for: "lockdown")
        let key = try store.loadSensitiveField("HostPrivateKey", for: "lockdown")
        let certificate = try store.loadSensitiveField("HostCertificate", for: "lockdown")
        check(host == "synthetic-host", "string preserved")
        check(key == "Base64:\n" + Data("synthetic-private-key".utf8).base64EncodedString(), "binary encoded without loss")
        check(certificate == "synthetic-certificate", "certificate string preserved")
        rejected { try store.loadSensitiveField("NotAllowed", for: "lockdown") }
        rejected { try store.loadSensitiveField("RootPrivateKey", for: "lockdown") }
        rejected { try store.loadSensitiveField("HostID", for: "../../outside") }
        rejected { try store.loadSensitiveField("HostID", for: "legacy-unknown") }

        // Legacy IDs are obtained from inventory, never from a filename or user-controlled path.
        let legacy = directory.appendingPathComponent("synthetic-legacy.plist")
        try original.write(to: legacy)
        let legacyID = store.inventory().first { $0.id.hasPrefix("legacy-") }!.id
        let legacyHost = try store.loadSensitiveField("HostID", for: legacyID)
        check(legacyHost == host, "legacy opaque id resolves")

        let remote: [String: Any] = ["public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32), "identifier": "synthetic-remote",
            "alt_irk": Data(repeating: 3, count: 16)]
        let remoteURL = directory.appendingPathComponent(PairingType.remote.fileName)
        let remoteBytes = try encoded(remote, format: .binary)
        try remoteBytes.write(to: remoteURL)
        for field in ["public_key", "private_key", "alt_irk"] {
            let value = try store.loadSensitiveField(field, for: "remote")
            check(value == "Base64:\n" + (remote[field] as! Data).base64EncodedString(), "remote binary field")
        }
        let identifier = try store.loadSensitiveField("identifier", for: "remote")
        check(identifier == "synthetic-remote", "remote identifier")
        rejected { try store.loadSensitiveField("HostID", for: "remote") }
        rejected { try store.loadSensitiveField("private_key", for: "lockdown") }
        var invalidRemote = remote
        invalidRemote["private_key"] = Data([1])
        try encoded(invalidRemote).write(to: remoteURL)
        rejected { try store.loadSensitiveField("identifier", for: "remote") }
        try remoteBytes.write(to: remoteURL)

        // Field disclosure is read-only: no file rewrite, preference or sidecar changes.
        let unchanged = try Data(contentsOf: canonical)
        let remoteUnchanged = try Data(contentsOf: remoteURL)
        check(unchanged == original && remoteUnchanged == remoteBytes, "original records unchanged")
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        check(Set(names) == Set([canonical.lastPathComponent, legacy.lastPathComponent, remoteURL.lastPathComponent]), "no sidecar created")
        check(defaults.persistentDomain(forName: suite)?.isEmpty != false, "no preference persisted")

        // Each fail-closed read is tested only with synthetic records.
        try fm.removeItem(at: canonical)
        rejected { try store.loadSensitiveField("HostID", for: "lockdown") }
        try fm.createSymbolicLink(at: canonical, withDestinationURL: legacy)
        rejected { try store.loadSensitiveField("HostID", for: "lockdown") }
        try fm.removeItem(at: canonical)
        try Data("synthetic-invalid-plist".utf8).write(to: canonical)
        rejected { try store.loadSensitiveField("HostID", for: "lockdown") }
        try Data(repeating: 0, count: PairingFileStore.maximumFileSize + 1).write(to: canonical)
        rejected { try store.loadSensitiveField("HostID", for: "lockdown") }
        try original.write(to: canonical)
        let link = root.appendingPathComponent("linked-directory")
        try fm.createSymbolicLink(at: link, withDestinationURL: directory)
        let linkedStore = PairingFileStore(directory: link, defaults: defaults)
        rejected { try linkedStore.loadSensitiveField("HostID", for: "lockdown") }
        var wrongType = lockdown
        wrongType["UDID"] = ["synthetic-nested-value"]
        try encoded(wrongType).write(to: canonical)
        rejected { try store.loadSensitiveField("UDID", for: "lockdown") }
        try original.write(to: canonical)

        var state = PairingFieldDisclosure()
        var reads = 0
        func load(_ text: String) -> String { reads += 1; return text }
        check(state.field == nil && state.value(for: "HostID", isActive: true) == nil, "initial mask")
        try state.toggle("HostID", isActive: true) { load(host) }
        check(state.value(for: "HostID", isActive: true) == host, "explicit reveal")
        check(state.value(for: "HostID", isActive: false) == nil, "inactive render gated immediately")
        check(!String(describing: state).contains(host) && !String(reflecting: state).contains(host), "descriptions redacted")
        try state.toggle("HostPrivateKey", isActive: true) { load(key) }
        check(state.value(for: "HostID", isActive: true) == nil, "previous field masked")
        check(state.value(for: "HostPrivateKey", isActive: true) == key, "only new field revealed")
        try state.toggle("HostPrivateKey", isActive: true) { load(key) }
        check(state.field == nil && reads == 2, "hide does not reread")
        try state.toggle("HostID", isActive: false) { load(host) }
        check(state.field == nil && reads == 2, "background cannot load")
        for _ in 0..<3 {
            try state.toggle("HostID", isActive: true) { load(host) }
            // The view calls this on disappear, every scene transition and reload.
            state.hide()
            check(state.field == nil && state.value(for: "HostID", isActive: true) == nil, "lifecycle reset does not restore")
        }
        try state.toggle("HostID", isActive: true) { load(host) }
        do {
            try state.toggle("RootPrivateKey", isActive: true) { throw PairingStoreError.sensitiveFieldUnavailable }
            fatalError("FAIL: expected loader error")
        } catch PairingStoreError.sensitiveFieldUnavailable { }
        check(state.field == nil && state.value(for: "HostID", isActive: true) == nil, "failed replacement clears prior value")
        try state.toggle("HostID", isActive: true) { try store.loadSensitiveField("HostID", for: "lockdown") }
        check(state.value(for: "HostID", isActive: true) == host, "store and transient state integration")
        state.hide()
        print("PASS: single-field disclosure, lifecycle reset logic, safe local reads and read-only synthetic fixtures")
    }
}
