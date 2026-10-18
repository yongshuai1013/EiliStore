import Foundation

private final class StagingFailureFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".pairing-edit-") {
            throw NSError(domain: "SYNTHETIC_PRIVATE_STORAGE_ERROR", code: 1)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

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
        func remote(_ overrides: [String: Any] = [:]) throws -> Data {
            var dict: [String: Any] = ["public_key": Data(repeating: 1, count: 32),
                "private_key": Data(repeating: 2, count: 32), "identifier": "synthetic-identifier"]
            overrides.forEach { dict[$0.key] = $0.value }
            return try plist(dict)
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
            check(urls.allSatisfy { $0.id.hasPrefix("legacy-") && UUID(uuidString: String($0.id.dropFirst("legacy-".count))) != nil }, "legacy ids are opaque UUIDs")
            check(Set(urls.map(\.id)).count == 2, "legacy ids are unique")
            let stableIDs = Set(urls.map(\.id))
            try put(valid(), at: dir.appendingPathComponent("a-new-legacy.plist"))
            let afterInsertion = store.inventory().filter { $0.id.hasPrefix("legacy-") }
            check(stableIDs.isSubset(of: Set(afterInsertion.map(\.id))), "legacy IDs remain stable when sort order changes")
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

        // Remote is structurally validated against the pinned Rust schema; automatic selection and explicit preferences fail closed.
        do {
            let (dir, defaults, store) = try fresh("remote-selection")
            let remoteURL = dir.appendingPathComponent(PairingType.remote.fileName)
            let validRemote = try remote(["alt_irk": Data(repeating: 3, count: 16)])
            try put(validRemote, at: remoteURL)
            check(store.selectedPairingFileURL() == remoteURL, "valid Remote selected when no Lockdown exists")
            let remoteInfo = store.inventory().first(where: { $0.type == .remote })!
            check(remoteInfo.isStructurallyValid && remoteInfo.isSelected, "Remote inventory structural validity and selection")
            check(remoteInfo.presentSensitiveFields.sorted() == ["alt_irk", "identifier", "private_key", "public_key"], "Remote sensitive field names use allowlist")
            let connection = try store.validatedConnectionData(at: remoteURL)
            check(connection.0 == .remote && connection.1 == validRemote, "connection API returns selected Remote bytes/type")
            try store.setPreferredProtocol(.lockdown)
            check(store.selectedPairingFileURL() == nil, "explicit Lockdown preference does not downgrade to Remote")
            try store.setPreferredProtocol(nil)
            let lockdown = dir.appendingPathComponent(PairingType.lockdown.fileName)
            try put(valid(), at: lockdown)
            check(store.selectedPairingFileURL() == lockdown, "automatic selection prefers valid Lockdown")
            try store.setPreferredProtocol(.remote)
            check(store.preferredProtocol == .remote && store.selectedPairingFileURL() == remoteURL, "valid installed Remote preference accepted")
            try put(Data("invalid".utf8), at: remoteURL)
            check(store.selectedPairingFileURL() == nil && store.preferredProtocol == nil, "invalid explicit Remote fails closed without downgrade")
            check(store.lockdownFileURL() == lockdown, "legacy accessor remains strictly Lockdown")
            let invalids: [Data] = [
                try remote(["public_key": Data(repeating: 0, count: 31)]),
                try remote(["private_key": Data(repeating: 0, count: 33)]),
                try remote(["identifier": ""]), try remote(["identifier": 7]),
                try remote(["alt_irk": Data(repeating: 0, count: 15)]),
                try remote(["alt_irk": "not bytes"]), try remote(["generated_by": "idevice"])
            ]
            for (index, bytes) in invalids.enumerated() {
                try put(bytes, at: remoteURL)
                check(store.inventory().first(where: { $0.type == .remote })?.isStructurallyValid == false, "invalid Remote schema rejected at fixture \(index)")
            }
            try put(validRemote, at: remoteURL)
            try store.setPreferredProtocol(.remote)
            let marker = "SYNTHETIC_REMOTE_SECRET"
            try put(try remote(["identifier": marker]), at: remoteURL)
            let rendered = store.inventory().filter { $0.type == .remote }.map { "\($0.id)|\($0.fileName)|\($0.presentSensitiveFields)" }.joined()
            check(!rendered.contains(marker), "Remote metadata never exposes identifier values")
            let hugeURL = dir.appendingPathComponent(PairingType.remote.fileName)
            try put(Data(repeating: 0x41, count: PairingFileStore.maximumFileSize + 1), at: hugeURL)
            check(store.selectedPairingFileURL() == nil, "oversized Remote rejected")
            try FileManager.default.removeItem(at: hugeURL)
            let target = root.appendingPathComponent("remote-link-target.plist")
            try put(validRemote, at: target)
            try FileManager.default.createSymbolicLink(at: hugeURL, withDestinationURL: target)
            check(store.selectedPairingFileURL() == nil, "Remote symlink rejected")
            do { _ = try store.validatedConnectionData(at: hugeURL); fatalError("FAIL: Remote symlink connection data") }
            catch { check(!error.localizedDescription.contains(marker), "Remote access error is sanitized") }
            defaults.removePersistentDomain(forName: "unused")
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

        // Annotations live only in a private sidecar, survive reload, and never alter pairing bytes or metadata.
        do {
            let (dir, defaults, store) = try fresh("annotations")
            let marker = "SYNTHETIC_CREDENTIAL_MARKER_ANNOTATION"
            let secretName = "legacy-\(marker).plist"
            let legacyURL = dir.appendingPathComponent(secretName)
            let bytes = try valid(["HostID": marker, "HostPrivateKey": Data(marker.utf8)])
            try put(bytes, at: legacyURL)
            let legacy = store.inventory().first { $0.id.hasPrefix("legacy-") }!
            let originalDate = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as! Date
            let value = PairingFileAnnotation(displayName: "  Friendly label  ", note: "  private note\nline\t2  ")
            try store.updateAnnotation(for: legacy.id, annotation: value, expected: .empty)
            let saved = store.inventory().first { $0.id == legacy.id }!
            check(saved.annotation == PairingFileAnnotation(displayName: "Friendly label", note: "private note\nline\t2"), "annotation trims outer whitespace and allows note newline/tab")
            check(saved.canEditAnnotation, "regular legacy file annotations editable")
            let savedPairingBytes = try Data(contentsOf: legacyURL)
            check(savedPairingBytes == bytes, "annotation save does not mutate pairing bytes")
            let nowDate = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as! Date
            check(nowDate == originalDate, "annotation save does not modify pairing timestamp")
            try store.setPreferredProtocol(.lockdown)
            let sidecar = dir.appendingPathComponent(".pairing-info.json")
            let sidecarBytes = try Data(contentsOf: sidecar)
            check(!String(decoding: sidecarBytes, as: UTF8.self).contains(marker), "sidecar does not contain filename or credential marker")
            check(defaults.dictionaryRepresentation().values.description.contains("lockdown"), "defaults may hold protocol preference only")
            let reloaded = PairingFileStore(directory: dir, defaults: defaults)
            check(reloaded.inventory().first { $0.id.hasPrefix("legacy-") }?.annotation == saved.annotation, "legacy annotation persists across store instances")
            let canonicalID = PairingType.lockdown.rawValue
            let canonicalSource = root.appendingPathComponent("annotations-canonical.plist")
            try put(valid(), at: canonicalSource); try store.importLockdown(from: canonicalSource)
            try store.updateAnnotation(for: canonicalID, annotation: PairingFileAnnotation(displayName: "Canonical", note: "text"), expected: .empty)
            try store.updateAnnotation(for: canonicalID, annotation: .empty, expected: PairingFileAnnotation(displayName: "Canonical", note: "text"))
            check(store.inventory().first { $0.id == canonicalID }?.annotation == .empty, "empty annotation clears entry")
        }

        // Invalid annotation inputs and optimistic concurrency failures preserve current metadata and plist bytes.
        do {
            let (dir, _, store) = try fresh("annotation-validation")
            let source = root.appendingPathComponent("annotation-validation.plist")
            try put(valid(), at: source); try store.importLockdown(from: source)
            let id = PairingType.lockdown.rawValue
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let baseline = try Data(contentsOf: file)
            let label = PairingFileAnnotation(displayName: "Kept", note: "safe")
            try store.updateAnnotation(for: id, annotation: label, expected: .empty)
            let invalid = [
                PairingFileAnnotation(displayName: String(repeating: "x", count: 61), note: ""),
                PairingFileAnnotation(displayName: "", note: String(repeating: "n", count: 301)),
                PairingFileAnnotation(displayName: "bad\u{0001}name", note: ""),
                PairingFileAnnotation(displayName: "ok", note: "bad\u{0007}note")
            ]
            for value in invalid {
                expectError(.invalidAnnotation, { try store.updateAnnotation(for: id, annotation: value, expected: label) }, "invalid annotation rejected")
                check(store.inventory().first { $0.id == id }?.annotation == label, "invalid annotation preserves metadata")
                let currentBytes = try Data(contentsOf: file)
                check(currentBytes == baseline, "invalid annotation preserves pairing bytes")
            }
            expectError(.annotationConflict, { try store.updateAnnotation(for: id, annotation: .empty, expected: .empty) }, "stale annotation conflict")
            check(store.inventory().first { $0.id == id }?.annotation == label, "stale update preserves metadata")
            for missingID in ["lockdown/../../outside", "legacy-not-a-real-id"] {
                expectError(.fileMissing, { try store.updateAnnotation(for: missingID, annotation: label, expected: .empty) }, "unknown/path traversal ID rejected")
            }
            try FileManager.default.removeItem(at: file)
            expectError(.fileMissing, { try store.updateAnnotation(for: id, annotation: label, expected: label) }, "missing pairing file rejected")
        }

        // Corrupt/symlink sidecars and symlink files/directories fail closed without changing targets.
        do {
            let (dir, _, store) = try fresh("annotation-filesystem")
            let source = root.appendingPathComponent("filesystem-source.plist")
            try put(valid(), at: source); try store.importLockdown(from: source)
            let id = PairingType.lockdown.rawValue
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let original = try Data(contentsOf: file)
            let sidecar = dir.appendingPathComponent(".pairing-info.json")
            try Data("not json".utf8).write(to: sidecar)
            expectError(.annotationUnavailable, { try store.updateAnnotation(for: id, annotation: PairingFileAnnotation(displayName: "X", note: ""), expected: .empty) }, "corrupt sidecar rejects update")
            let afterCorrupt = try Data(contentsOf: file)
            check(afterCorrupt == original && store.lockdownFileURL() == file, "corrupt sidecar leaves usable credentials unchanged")
            try FileManager.default.removeItem(at: sidecar)
            let target = root.appendingPathComponent("sidecar-target")
            try Data("target sentinel".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            expectError(.annotationUnavailable, { try store.updateAnnotation(for: id, annotation: PairingFileAnnotation(displayName: "X", note: ""), expected: .empty) }, "symlink sidecar rejected")
            let targetAfterSidecarLink = try Data(contentsOf: target)
            check(targetAfterSidecarLink == Data("target sentinel".utf8), "sidecar symlink target unchanged")
            try FileManager.default.removeItem(at: sidecar)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            expectError(.fileMissing, { try store.updateAnnotation(for: id, annotation: PairingFileAnnotation(displayName: "X", note: ""), expected: .empty) }, "symlink pairing target rejected")
            let targetAfterPairingLink = try Data(contentsOf: target)
            check(targetAfterPairingLink == Data("target sentinel".utf8), "pairing symlink target unchanged")
        }
        do {
            let outside = root.appendingPathComponent("outside-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let external = outside.appendingPathComponent("PairingFile_Lockdown.plist")
            try put(valid(), at: external)
            let linkDir = root.appendingPathComponent("linked-store", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: outside)
            let store = PairingFileStore(directory: linkDir, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            expectError(.fileMissing, { try store.updateAnnotation(for: "lockdown", annotation: PairingFileAnnotation(displayName: "X", note: ""), expected: .empty) }, "symlink directory rejected")
            let externalBytes = try Data(contentsOf: external)
            let expectedExternal = try valid()
            check(externalBytes == expectedExternal, "directory symlink target unchanged")
        }

        // Remote metadata remains display-only and cannot enable Remote fallback; labels stay with a legacy file slot.
        do {
            let (dir, _, store) = try fresh("remote-and-legacy-move")
            let remote = dir.appendingPathComponent(PairingType.remote.fileName)
            try put(valid(), at: remote)
            try store.updateAnnotation(for: PairingType.remote.rawValue, annotation: PairingFileAnnotation(displayName: "Remote label", note: "note"), expected: .empty)
            check(store.lockdownFileURL() == nil, "Remote annotation does not enable Lockdown fallback")
            check(store.inventory().first { $0.id == "remote" }?.annotation?.displayName == "Remote label", "Remote annotation stored")
            let a = dir.appendingPathComponent("a-legacy.plist"), b = dir.appendingPathComponent("z-legacy.plist")
            try put(valid(), at: a); try put(valid(), at: b)
            let aInfo = store.inventory().first { $0.fileName == "舊版配對檔 1" }!
            let bInfo = store.inventory().first { $0.fileName == "舊版配對檔 2" }!
            let label = PairingFileAnnotation(displayName: "Belongs to A", note: "slot")
            try store.updateAnnotation(for: aInfo.id, annotation: label, expected: .empty)
            try put(valid(), at: dir.appendingPathComponent("0-earlier.plist"))
            let reordered = store.inventory()
            check(reordered.contains(where: { $0.id == aInfo.id && $0.annotation == label }), "legacy annotation remains with same URL when ordering changes")
            check(reordered.contains(where: { $0.id == bInfo.id }), "other legacy ID stable when ordering changes")
            let reloaded = PairingFileStore(directory: dir, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            check(reloaded.inventory().contains(where: { $0.fileName == "舊版配對檔 2" && $0.annotation == label }), "legacy annotation persists across store instance")
        }

        // Delete clears a canonical annotation and reset removes the sidecar; sidecars use mode 0600.
        do {
            let (dir, _, store) = try fresh("annotation-delete-reset")
            let source = root.appendingPathComponent("annotation-delete-reset.plist")
            try put(valid(), at: source); try store.importLockdown(from: source)
            let id = PairingType.lockdown.rawValue
            try store.updateAnnotation(for: id, annotation: PairingFileAnnotation(displayName: "Delete me", note: ""), expected: .empty)
            let sidecar = dir.appendingPathComponent(".pairing-info.json")
            #if canImport(Darwin) || canImport(Glibc)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: sidecar.path), let permissions = attrs[.posixPermissions] as? NSNumber {
                check(permissions.intValue & 0o777 == 0o600, "annotation sidecar permissions are 0600")
            }
            #endif
            try store.delete(.lockdown)
            check(store.inventory().first { $0.id == id }?.annotation == nil || store.inventory().first { $0.id == id }?.annotation == .empty, "delete clears canonical annotation")
            try store.reset()
            check(!FileManager.default.fileExists(atPath: sidecar.path), "reset removes annotation sidecar")
        }

        // A failed import must preserve the previous pairing file and its file-slot annotation.
        do {
            let (dir, _, store) = try fresh("bad-import-preserves-label")
            let good = root.appendingPathComponent("good-with-label.plist")
            try put(valid(), at: good); try store.importLockdown(from: good)
            let id = PairingType.lockdown.rawValue
            let label = PairingFileAnnotation(displayName: "Keep label", note: "local")
            try store.updateAnnotation(for: id, annotation: label, expected: .empty)
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let before = try Data(contentsOf: file)
            let bad = root.appendingPathComponent("bad-with-label.plist")
            try put(Data("bad import".utf8), at: bad)
            expectError(.invalidLockdown, { try store.importLockdown(from: bad) }, "bad import with annotation")
            let afterBadImport = try Data(contentsOf: file)
            check(afterBadImport == before, "failed import preserves pairing bytes")
            check(store.inventory().first { $0.id == id }?.annotation == label, "failed import preserves slot annotation")
            try store.importLockdown(from: good)
            check(store.inventory().first { $0.id == id }?.annotation == label, "successful replacement preserves file-slot annotation")
        }
        // XML editor snapshots preserve original bytes until an explicit validated save.
        do {
            let (dir, _, store) = try fresh("xml-edit")
            let source = root.appendingPathComponent("xml-original.plist")
            let original = try valid()
            try put(original, at: source); try store.importLockdown(from: source)
            let id = PairingType.lockdown.rawValue
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let annotation = PairingFileAnnotation(displayName: "Canonical label", note: "kept")
            try store.updateAnnotation(for: id, annotation: annotation, expected: .empty)
            let bytesBefore = try Data(contentsOf: file)
            let document = try store.loadXML(for: id)
            check(document.text == String(data: bytesBefore, encoding: .utf8), "XML load preserves original text")
            let bytesAfterLoad = try Data(contentsOf: file)
            check(bytesAfterLoad == bytesBefore, "cancel/no save leaves pairing bytes unchanged")
            let edited = try plist(["HostID": "edited-host", "SystemBUID": "edited-buid", "HostPrivateKey": Data("edited-key".utf8), "HostCertificate": Data("edited-cert".utf8), "RootCertificate": Data("edited-root".utf8), "DeviceCertificate": Data("edited-device".utf8)])
            let editedText = String(data: edited, encoding: .utf8)!
            try store.validateXML(editedText, for: .lockdown)
            try store.saveXML(editedText, replacing: document)
            let bytesAfterSave = try Data(contentsOf: file)
            check(bytesAfterSave == Data(editedText.utf8), "save writes exact UTF-8 bytes")
            check(store.lockdownFileURL() == file, "saved valid content remains selected")
            check(store.inventory().first { $0.id == id }?.isStructurallyValid == true, "saved content structurally valid")
            check(store.inventory().first { $0.id == id }?.annotation == annotation, "canonical annotation preserved")
            #if canImport(Darwin) || canImport(Glibc)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            check((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777 == 0o600, "saved plist permissions are private")
            #endif
            let stagedNames = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            check(!stagedNames.contains(where: { $0.hasPrefix(".pairing-edit-") }), "successful save leaves no staging file")
        }

        // Legacy annotation identity follows atomic replacement; malformed XML remains repairable.
        do {
            let (dir, _, store) = try fresh("xml-legacy")
            let legacyURL = dir.appendingPathComponent("legacy-record.plist")
            try put(try valid(), at: legacyURL)
            let legacyID = store.inventory().first { $0.id.hasPrefix("legacy-") }!.id
            let label = PairingFileAnnotation(displayName: "Legacy label", note: "migration")
            try store.updateAnnotation(for: legacyID, annotation: label, expected: .empty)
            let doc = try store.loadXML(for: legacyID)
            let newText = String(data: try valid(["HostID": "legacy-edited"]), encoding: .utf8)!
            try store.saveXML(newText, replacing: doc)
            let migratedAnnotation = store.inventory().first { $0.id == legacyID }?.annotation
            check(migratedAnnotation == label, "legacy annotation identity migrates across atomic replacement")
            let malformed = "<plist><dict><key>HostID</key><string>repair</string>"
            try put(Data(malformed.utf8), at: legacyURL)
            let broken = try store.loadXML(for: legacyID)
            check(broken.text == malformed, "malformed XML-like source loads for repair")
        }

        // Invalid editor submissions, unsafe declarations and conflicts are rejected without mutation.
        do {
            let (dir, _, store) = try fresh("xml-reject")
            let source = root.appendingPathComponent("xml-reject-source.plist")
            try put(try valid(), at: source); try store.importLockdown(from: source)
            let id = PairingType.lockdown.rawValue
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let baseline = try Data(contentsOf: file)
            let doc = try store.loadXML(for: id)
            let bad: [(String, PairingStoreError)] = [("<plist><broken", .invalidXML),
                (try String(data: plist(["not-a-dictionary"]), encoding: .utf8)!, .invalidXML),
                (try String(data: plist(["not": "lockdown"]), encoding: .utf8)!, .invalidLockdown),
                (try String(data: plist(["HostID": "", "SystemBUID": "b", "HostPrivateKey": Data([1]), "HostCertificate": Data([1]), "RootCertificate": Data([1]), "DeviceCertificate": Data([1])]), encoding: .utf8)!, .invalidLockdown),
                (try String(data: plist(["HostID": "h", "SystemBUID": " ", "HostPrivateKey": Data([1]), "HostCertificate": Data([1]), "RootCertificate": Data([1]), "DeviceCertificate": Data([1])]), encoding: .utf8)!, .invalidLockdown),
                (String(repeating: "x", count: PairingFileStore.maximumFileSize + 1), .tooLarge)]
            for (text, expected) in bad {
                expectError(expected, { try store.saveXML(text, replacing: doc) }, "invalid editor input")
                let unchanged = try Data(contentsOf: file)
                check(unchanged == baseline, "invalid XML submission preserves original bytes immediately")
            }
            let entity = "<!DOCTYPE plist [<!ENTITY x SYSTEM 'file:///synthetic'>]><plist version=\"1.0\"><dict/></plist>"
            let custom = "<!DOCTYPE plist SYSTEM 'http://invalid.example/synthetic.dtd'><plist version=\"1.0\"><dict/></plist>"
            expectError(.unsafeXML, { try store.validateXML(entity, for: .lockdown) }, "entity declaration rejected")
            expectError(.unsafeXML, { try store.validateXML(custom, for: .lockdown) }, "custom doctype rejected")
            let appleDocType = doc.text
            try store.validateXML(appleDocType, for: .lockdown)
            let utf8Apple = Data([0xEF, 0xBB, 0xBF]) + Data(appleDocType.utf8)
            try put(utf8Apple, at: file)
            let appleSnapshot = try store.loadXML(for: id)
            check(appleSnapshot.text.contains("<!DOCTYPE plist PUBLIC"), "UTF-8 BOM standard Apple DOCTYPE accepted")
            try store.validateXML(appleSnapshot.text, for: .lockdown)
            for (name, encoded) in [
                ("utf8-bom-custom", Data([0xEF, 0xBB, 0xBF]) + Data(custom.utf8)),
                ("utf16-custom", custom.data(using: .utf16)!),
                ("utf32-entity", "<!DOCTYPE plist [<!ENTITY x 'synthetic'>]><plist version=\"1.0\"><dict/></plist>".data(using: .utf32)!)
            ] {
                let unsafeFile = dir.appendingPathComponent("\(name).plist")
                let priorIDs = Set(store.inventory().filter { $0.id.hasPrefix("legacy-") }.map(\.id))
                try put(encoded, at: unsafeFile)
                let legacyEntries = store.inventory().filter { $0.id.hasPrefix("legacy-") }
                guard let entry = legacyEntries.first(where: { !priorIDs.contains($0.id) }) else { fatalError("FAIL: synthetic unsafe plist inventoried") }
                expectError(.unsafeXML, { _ = try store.loadXML(for: entry.id) }, "\(name) unsafe declaration rejected")
            }
            try baseline.write(to: file)
            let bytesAfterRejects = try Data(contentsOf: file)
            check(bytesAfterRejects == baseline, "rejections preserve original bytes")
            try Data("external newer bytes".utf8).write(to: file)
            expectError(.xmlConflict, { try store.saveXML(doc.text, replacing: doc) }, "external edit conflict")
            let conflictBytes = try Data(contentsOf: file)
            check(conflictBytes == Data("external newer bytes".utf8), "conflict preserves newer external bytes")
        }

        // Binary originals are presented as XML and only change on explicit save; IDs and store ownership fail closed.
        do {
            let (dir, _, store) = try fresh("xml-binary")
            let dictionary: [String: Any] = ["HostID": "binary", "SystemBUID": "buid", "HostPrivateKey": Data([1]), "HostCertificate": Data([2]), "RootCertificate": Data([3]), "DeviceCertificate": Data([4])]
            let binary = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            try put(binary, at: file)
            let doc = try store.loadXML(for: "lockdown")
            check(doc.isConvertedToXML && doc.text.hasPrefix("<?xml"), "binary plist safely converts in editor snapshot")
            let binaryBeforeSave = try Data(contentsOf: file)
            check(binaryBeforeSave == binary, "binary source unchanged before save")
            try store.saveXML(doc.text, replacing: doc)
            let binaryAfterSave = try Data(contentsOf: file)
            check(binaryAfterSave == Data(doc.text.utf8), "binary converts only on save")
            expectError(.xmlUnavailable, { _ = try store.loadXML(for: "unknown/../id") }, "unknown path ID rejected")
            expectError(.unsupportedProtocol, { _ = try store.loadXML(for: "remote") }, "Remote load unsupported")
            expectError(.unsupportedProtocol, { try store.validateXML(doc.text, for: .remote) }, "Remote validation unsupported")
            let otherStore = PairingFileStore(directory: dir, defaults: UserDefaults(suiteName: UUID().uuidString)!)
            expectError(.xmlConflict, { try otherStore.saveXML(doc.text, replacing: doc) }, "foreign store document rejected")
            let marker = "SYNTHETIC_XML_SECRET_73B2"
            let secretFile = dir.appendingPathComponent("secret-\(marker).plist")
            try put(try valid(["HostID": marker]), at: secretFile)
            let secretDoc = try store.loadXML(for: store.inventory().first { $0.fileName == "舊版配對檔 1" }!.id)
            check(!String(describing: secretDoc).contains(marker) && !String(reflecting: secretDoc).contains(marker), "document descriptions redact content")
            try FileManager.default.removeItem(at: file)
            expectError(.xmlUnavailable, { _ = try store.loadXML(for: "lockdown") }, "missing source rejected")
        }

        // A genuine staged-write failure or a symlink replacement never mutates the original/target.
        do {
            let (dir, defaults, _) = try fresh("xml-write-failure")
            let file = dir.appendingPathComponent(PairingType.lockdown.fileName)
            let original = try valid()
            try put(original, at: file)
            let store = PairingFileStore(directory: dir, defaults: defaults, fileManager: StagingFailureFileManager())
            let document = try store.loadXML(for: "lockdown")
            expectError(.storageFailed, { try store.saveXML(document.text, replacing: document) }, "staged permission failure")
            let unchanged = try Data(contentsOf: file)
            check(unchanged == original, "failed staging preserves original pairing bytes")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            check(!remaining.contains(where: { $0.hasPrefix(".pairing-edit-") }), "failed staging is cleaned up")

            let target = root.appendingPathComponent("xml-link-target.plist")
            try put(original, at: target)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            expectError(.xmlUnavailable, { _ = try store.loadXML(for: "lockdown") }, "XML load rejects symlink")
            expectError(.xmlUnavailable, { try store.saveXML(document.text, replacing: document) }, "XML save rejects symlink replacing original")
            let targetBytes = try Data(contentsOf: target)
            check(targetBytes == original, "XML symlink target remains unchanged")
        }

        print("PairingFileStore regression tests passed (structural validation only; no cryptographic verification).")
    }
}
