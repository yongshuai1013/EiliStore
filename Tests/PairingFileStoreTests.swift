import Foundation

@main
struct PairingFileStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PairingFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        func expectError(_ expected: PairingStoreError, _ operation: () throws -> Void, _ message: String) {
            do { try operation(); fatalError("FAIL: expected \(message)") }
            catch let error as PairingStoreError {
                check(String(describing: error) == String(describing: expected), "wrong error for \(message): \(error)")
            } catch { fatalError("FAIL: unexpected error for \(message): \(error)") }
        }
        func fresh(_ name: String) throws -> (URL, UserDefaults, PairingFileStore) {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let suite = "PairingFileStoreTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return (dir, defaults, PairingFileStore(directory: dir, defaults: defaults))
        }
        func plist(_ object: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        }
        func valid(_ overrides: [String: Any] = [:]) throws -> Data {
            var dict: [String: Any] = ["HostID": "dummy-host-id", "SystemBUID": "dummy-system-buid",
                "HostPrivateKey": Data("dummy-private-key".utf8), "HostCertificate": Data("dummy-host-cert".utf8),
                "RootCertificate": Data("dummy-root-cert".utf8), "DeviceCertificate": Data("dummy-device-cert".utf8)]
            overrides.forEach { dict[$0.key] = $0.value }
            return try plist(dict)
        }
        func put(_ data: Data, at url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        // Canonical missing, then canonical structurally valid and selected.
        do {
            let (dir, _, store) = try fresh("canonical")
            check(store.lockdownFileURL() == nil, "missing canonical must not resolve")
            check(store.inventory().first(where: { $0.type == .lockdown })?.isInstalled == false, "missing canonical inventory")
            let source = root.appendingPathComponent("canonical-source.plist")
            try put(valid(), at: source)
            try store.importLockdown(from: source)
            let canonical = dir.appendingPathComponent(PairingType.lockdown.fileName)
            check(store.lockdownFileURL() == canonical, "canonical valid file selected")
            let info = store.inventory().first(where: { $0.id == PairingType.lockdown.rawValue })!
            check(info.isStructurallyValid && info.isSelected, "canonical inventory validity/selection")
            // This parser checks plist shape and required nonempty fields only; it is not cryptographic validation.
        }

        // Invalid replacement must leave the previous canonical bytes untouched; exercise wrong types and empty fields.
        do {
            let (dir, _, store) = try fresh("replacement")
            let good = root.appendingPathComponent("good.plist")
            try put(valid(), at: good); try store.importLockdown(from: good)
            let canonical = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let previous = try Data(contentsOf: canonical)
            let badInputs: [Data] = [
                try plist(["HostID": 9, "SystemBUID": "b", "HostPrivateKey": Data([1]), "HostCertificate": Data([1]), "RootCertificate": Data([1]), "DeviceCertificate": Data([1])]),
                try valid(["HostID": " \n"]), try valid(["SystemBUID": "\t"]),
                try valid(["HostPrivateKey": ""]), try valid(["HostCertificate": 5]),
                try valid(["RootCertificate": Data()]), try valid(["DeviceCertificate": ["not": "bytes"]]),
                Data("not a plist".utf8)
            ]
            for (index, bytes) in badInputs.enumerated() {
                let source = root.appendingPathComponent("invalid-\(index).plist")
                try put(bytes, at: source)
                expectError(.invalidLockdown, { try store.importLockdown(from: source) }, "invalid lockdown structure")
                let current = try Data(contentsOf: canonical)
                check(current == previous, "invalid replacement preserves prior bytes")
            }
            check(store.lockdownFileURL() == canonical, "prior valid canonical remains selected")
        }

        // Legacy fallback is sorted deterministically and UI names never disclose original device-like names.
        do {
            let (dir, _, store) = try fresh("legacy")
            let secretName = "UDID-SYNTHETIC-DEVICE-SECRET.plist"
            try put(valid(), at: dir.appendingPathComponent("z-legacy.plist"))
            try put(valid(), at: dir.appendingPathComponent(secretName))
            let urls = store.inventory().filter { $0.id.hasPrefix("legacy-") }
            check(urls.count == 2, "both legacy plists inventoried")
            check(urls.map(\.id) == ["legacy-0", "legacy-1"], "legacy ids deterministic")
            check(urls.map(\.fileName) == ["舊版配對檔 1", "舊版配對檔 2"], "legacy display names redacted")
            check(!urls.contains(where: { $0.fileName.contains("SYNTHETIC") || $0.id.contains("SYNTHETIC") }), "legacy metadata redacts names")
            check(store.lockdownFileURL() == dir.appendingPathComponent(secretName), "sorted valid legacy fallback")
        }

        // A Remote plist that looks like Lockdown must never serve as the Lockdown fallback.
        do {
            let (dir, _, store) = try fresh("remote-only")
            try put(valid(), at: dir.appendingPathComponent(PairingType.remote.fileName))
            check(store.lockdownFileURL() == nil, "Remote canonical never used as fallback")
            check(store.inventory().first(where: { $0.type == .remote })?.isStructurallyValid == false, "Remote is not validated as Lockdown")
        }

        // Oversize input, symbolic links and unsupported preference are rejected.
        do {
            let (_, defaults, store) = try fresh("reject")
            let huge = root.appendingPathComponent("oversize.plist")
            try put(Data(repeating: 0x41, count: PairingFileStore.maximumFileSize + 1), at: huge)
            expectError(.tooLarge, { try store.importLockdown(from: huge) }, "oversize import")
            let target = root.appendingPathComponent("symlink-target.plist")
            try put(valid(), at: target)
            let link = root.appendingPathComponent("symlink.plist")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            expectError(.unreadable, { try store.importLockdown(from: link) }, "symlink import")
            expectError(.unsupportedProtocol, { try store.setPreferredProtocol(.remote) }, "Remote preference")
            check(store.preferredProtocol == nil, "Remote preference remains unset")
            try store.setPreferredProtocol(.lockdown)
            check(store.preferredProtocol == .lockdown, "Lockdown preference accepted")
            check(defaults.string(forKey: "pairing.preferredProtocol") == "lockdown", "preference persisted")
        }

        // UI-facing metadata and localized errors must not contain any synthetic credential markers.
        do {
            let (dir, defaults, store) = try fresh("redaction")
            let marker = "SYNTHETIC_SECRET_MARKER_9F31"
            try put(try valid(["HostID": marker, "SystemBUID": "dummy-system-buid", "HostPrivateKey": Data(marker.utf8)]), at: dir.appendingPathComponent("sensitive-\(marker).plist"))
            let info = store.inventory()
            let rendered = info.map { "\($0.id)|\($0.fileName)|\($0.type.title)|\($0.presentSensitiveFields)" }.joined(separator: "\n")
            check(!rendered.contains(marker), "metadata descriptions exclude synthetic secret")
            let source = root.appendingPathComponent("bad-secret.plist")
            try put(try plist(["HostID": marker]), at: source)
            do { try store.importLockdown(from: source); fatalError("FAIL: expected invalid import") }
            catch { check(!(error.localizedDescription).contains(marker), "error description excludes synthetic secret") }
            try store.setPreferredProtocol(.lockdown)
            try store.reset()
            check(!FileManager.default.fileExists(atPath: dir.path), "reset removes canonical and legacy files")
            check(store.preferredProtocol == nil, "reset clears preference")
            check(defaults.string(forKey: "pairing.preferredProtocol") == nil, "reset removes preference key")
        }

        // Delete only the chosen canonical file, then fall back to a valid legacy Lockdown record.
        do {
            let (dir, _, store) = try fresh("single-delete")
            let canonical = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let remote = dir.appendingPathComponent(PairingType.remote.fileName)
            let legacy = dir.appendingPathComponent("legacy.plist")
            try put(valid(), at: canonical)
            try put(valid(), at: legacy)
            try put(Data("opaque remote record".utf8), at: remote)
            try store.delete(.lockdown)
            check(store.lockdownFileURL() == legacy, "deleting canonical allows valid legacy fallback")
            check(FileManager.default.fileExists(atPath: remote.path), "Lockdown delete preserves Remote")
            try store.delete(.remote)
            check(!FileManager.default.fileExists(atPath: remote.path), "Remote delete removes only Remote")
            check(store.lockdownFileURL() == legacy, "Remote delete preserves selected legacy")
            try put(Data("invalid canonical".utf8), at: canonical)
            let invalid = store.inventory().first(where: { $0.id == "lockdown" })!
            check(invalid.isInstalled && !invalid.isStructurallyValid && !invalid.isSelected, "invalid canonical is installed but never selected")
            try put(valid(), at: remote)
            try store.setPreferredProtocol(.lockdown)
            try store.reset()
            check(!FileManager.default.fileExists(atPath: canonical.path), "reset clears invalid canonical")
            check(!FileManager.default.fileExists(atPath: remote.path), "reset clears Remote")
            check(!FileManager.default.fileExists(atPath: legacy.path), "reset clears legacy")
            check(store.lockdownFileURL() == nil && store.preferredProtocol == nil, "reset clears selection and preference")
            try store.reset() // Reset and missing-file delete are idempotent.
            try store.delete(.lockdown)
        }

        // On POSIX filesystems, imported data is private (0600); skip when the platform cannot report it.
        #if canImport(Darwin) || canImport(Glibc)
        do {
            let (dir, _, store) = try fresh("permissions")
            let source = root.appendingPathComponent("permissions-source.plist")
            try put(valid(), at: source); try store.importLockdown(from: source)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(PairingType.lockdown.fileName).path),
               let permissions = attrs[.posixPermissions] as? NSNumber {
                check(permissions.intValue & 0o777 == 0o600, "canonical permissions are 0600")
            }
        }
        #endif
        print("PairingFileStore regression tests passed (structural validation only; no cryptographic verification).")
    }
}
