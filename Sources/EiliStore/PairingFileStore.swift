import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A short-lived editor snapshot, never persisted or included in diagnostics.
struct PairingXMLDocument: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id = UUID()
    let text: String
    let type: PairingType
    let isConvertedToXML: Bool
    fileprivate let originalData: Data
    fileprivate let target: URL
    fileprivate let fileID: String
    fileprivate let storeID: UUID

    var description: String { "PairingXMLDocument(local content hidden)" }
    var debugDescription: String { description }
}

enum PairingType: String, CaseIterable, Identifiable, Sendable {
    case lockdown, remote

    var id: String { rawValue }
    var title: String { self == .lockdown ? "Lockdown" : "Remote Pairing" }
    var fileName: String {
        self == .lockdown ? "PairingFile_Lockdown.plist" : "PairingFile_RemoteRP.plist"
    }
}

/// This is deliberately a display-only allowlist. Never retain identifiers or credential values here.
struct PairingFileInfo: Identifiable, Sendable {
    let id: String
    let type: PairingType
    let fileName: String
    let isInstalled: Bool
    let isStructurallyValid: Bool
    let isSelected: Bool
    let fileSize: Int64?
    let dateCreated: Date?
    let dateModified: Date?
    let presentSensitiveFields: [String]
    let annotation: PairingFileAnnotation?
    let canEditAnnotation: Bool
}

enum PairingStoreError: Error, LocalizedError {
    case invalidLockdown, unreadable, tooLarge, storageFailed, unsupportedProtocol
    case invalidAnnotation, annotationUnavailable, annotationConflict, fileMissing
    case invalidXML, unsafeXML, xmlConflict, xmlUnavailable, xmlBusy
    case sensitiveFieldUnavailable

    var errorDescription: String? {
        switch self {
        case .sensitiveFieldUnavailable: return "無法安全顯示此欄位，請重新整理後再試。"
        case .invalidLockdown: return "這不是完整的 Lockdown 配對檔。請重新產生後匯入；現有檔案未被替換。"
        case .unreadable: return "無法讀取配對檔。請確認檔案可用並重試。"
        case .tooLarge: return "配對檔過大，已拒絕匯入。"
        case .storageFailed: return "無法更新配對檔儲存空間，請重新整理後確認狀態。"
        case .unsupportedProtocol: return "Remote 僅可選用已儲存且結構有效的配對檔；不支援 Remote 匯入或原始 XML 編輯。"
        case .invalidAnnotation: return "顯示名稱最多 60 字、備註最多 300 字；名稱不能換行，亦不能包含控制字元。"
        case .annotationUnavailable: return "無法讀取或儲存本機資訊，配對檔與憑證未變更。請重新整理後再試。"
        case .annotationConflict: return "本機資訊已在其他畫面更新，請取消編輯並重新整理後再試。"
        case .fileMissing: return "配對檔已移除或無法安全讀取，未儲存本機資訊。"
        case .invalidXML: return "XML 語法或 plist 格式無效，未修改原始配對檔。"
        case .unsafeXML: return "不支援自訂 DTD 或實體宣告，未修改原始配對檔。"
        case .xmlConflict: return "原始配對檔已變更，未覆寫檔案。請保留所需修改，取消並重新載入後再試。"
        case .xmlUnavailable: return "配對檔已移除或無法安全讀寫，未儲存 XML。"
        case .xmlBusy: return "安裝、刷新或傳輸正在進行，未儲存 XML。請稍後重試。"
        }
    }
}

/// Keeps the existing private app-container location used by the Rust clients.
/// All consumers resolve Lockdown through this store; Remote files must never become a fallback.
final class PairingFileStore: @unchecked Sendable {
    static let shared = PairingFileStore()
    static let maximumFileSize = 4 * 1024 * 1024
    private static let preferenceKey = "pairing.preferredProtocol"
    private let directory: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private let storeID = UUID()
    private var legacyIdentifiers: [URL: String] = [:]
    private static let annotationsFileName = ".pairing-info.json"
    private static let maximumAnnotationsSize = 64 * 1024

    init(directory: URL? = nil, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.directory = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PairingFiles", isDirectory: true)
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var preferredProtocol: PairingType? {
        lock.lock(); defer { lock.unlock() }
        // A Remote preference is meaningful only while a valid installed Remote record exists.
        switch defaults.string(forKey: Self.preferenceKey) {
        case PairingType.lockdown.rawValue: return .lockdown
        case PairingType.remote.rawValue:
            return validRemoteURL() == nil ? nil : .remote
        default: return nil
        }
    }

    func setPreferredProtocol(_ type: PairingType?) throws {
        lock.lock(); defer { lock.unlock() }
        if type == .remote, validRemoteURL() == nil { throw PairingStoreError.unsupportedProtocol }
        if let type {
            defaults.set(type.rawValue, forKey: Self.preferenceKey)
        } else {
            defaults.removeObject(forKey: Self.preferenceKey)
        }
    }

    func lockdownFileURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return selectedLockdownURL()
    }

    /// Resolves the selected pairing record. Explicit preferences fail closed; automatic selection
    /// prefers a valid Lockdown record (including legacy) and then a valid canonical Remote record.
    func selectedPairingFileURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        switch defaults.string(forKey: Self.preferenceKey) {
        case PairingType.remote.rawValue: return validRemoteURL()
        case PairingType.lockdown.rawValue: return selectedLockdownURL()
        default: return selectedLockdownURL() ?? validRemoteURL()
        }
    }

    /// Bounded, symlink-safe connection bytes for the currently selected, structurally valid record.
    func validatedConnectionData(at url: URL) throws -> (PairingType, Data) {
        lock.lock(); defer { lock.unlock() }
        guard selectedPairingFileURL() == url else { throw PairingStoreError.fileMissing }
        do {
            let data = try readBoundedData(at: url)
            if url.lastPathComponent == PairingType.remote.fileName {
                guard remoteDictionary(data) != nil else { throw PairingStoreError.fileMissing }
                return (.remote, data)
            }
            guard lockdownDictionary(data) != nil else { throw PairingStoreError.fileMissing }
            return (.lockdown, data)
        } catch { throw PairingStoreError.fileMissing }
    }

    func inventory() -> [PairingFileInfo] {
        lock.lock(); defer { lock.unlock() }
        let selected = selectedPairingFileURL()
        let annotations = try? readAnnotations()
        let canonical = PairingType.allCases.map { type in
            info(at: directory.appendingPathComponent(type.fileName), type: type,
                 displayName: type.fileName, id: type.rawValue, selected: selected, annotations: annotations)
        }
        // Legacy names can contain a device identifier. Use numbered aliases, never the original name.
        let legacy = legacyURLs().enumerated().map { index, url in
            if legacyIdentifiers[url] == nil { legacyIdentifiers[url] = "legacy-\(UUID().uuidString)" }
            return info(at: url, type: .lockdown, displayName: "舊版配對檔 \(index + 1)",
                        id: legacyIdentifiers[url]!, selected: selected, annotations: annotations)
        }
        return canonical + legacy
    }

    private static func sensitiveKeys(for type: PairingType) -> [String] {
        type == .lockdown
            ? ["SystemBUID", "HostID", "UDID", "HardwareUDID", "WiFiMACAddress", "WifiMAC", "HostPrivateKey", "RootPrivateKey", "HostCertificate", "RootCertificate", "DeviceCertificate", "EscrowBag"]
            : ["public_key", "private_key", "identifier", "alt_irk"]
    }

    /// Explicit single-field, local-screen access. No values enter inventory, sidecars or diagnostics.
    func loadSensitiveField(_ field: String, for id: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let type: PairingType = id == PairingType.remote.rawValue ? .remote : .lockdown
        guard Self.sensitiveKeys(for: type).contains(field),
              let url = annotationTarget(for: id) else { throw PairingStoreError.sensitiveFieldUnavailable }
        do {
            let data = try readBoundedData(at: url)
            let dictionary = type == .lockdown ? lockdownDictionary(data) : remoteDictionary(data)
            if let value = dictionary?[field] as? String { return value }
            if let value = dictionary?[field] as? Data {
                return "Base64:\n" + value.base64EncodedString(options: .lineLength64Characters)
            }
            throw PairingStoreError.sensitiveFieldUnavailable
        } catch {
            // Parser/filesystem errors may contain private data or paths. Never forward them.
            throw PairingStoreError.sensitiveFieldUnavailable
        }
    }

    /// Explicit local-editor access only. Inventory and connection clients never receive this snapshot.
    func loadXML(for id: String) throws -> PairingXMLDocument {
        lock.lock(); defer { lock.unlock() }
        guard id != PairingType.remote.rawValue else { throw PairingStoreError.unsupportedProtocol }
        guard let url = annotationTarget(for: id) else { throw PairingStoreError.xmlUnavailable }
        let data: Data
        do { data = try readBoundedData(at: url) }
        catch PairingStoreError.tooLarge { throw PairingStoreError.tooLarge }
        catch { throw PairingStoreError.xmlUnavailable }

        var format = PropertyListSerialization.PropertyListFormat.xml
        let utf8 = String(data: data, encoding: .utf8)
        if !data.starts(with: Data("bplist00".utf8)) {
            let decoded: String?
            if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
                decoded = String(data: data, encoding: .utf32)
            } else if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
                decoded = String(data: data, encoding: .utf16)
            } else {
                decoded = utf8
            }
            guard let decoded else { throw PairingStoreError.invalidXML }
            try checkXMLDeclarations(decoded)
        }
        let object = try? PropertyListSerialization.propertyList(from: data, format: &format)
        let text: String
        let converted: Bool
        if let utf8, utf8.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            // Also allow malformed XML to be repaired; validation is mandatory before saving.
            text = utf8
            converted = false
        } else if let object,
                  let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0),
                  let encoded = String(data: xml, encoding: .utf8) {
            text = encoded
            converted = true
        } else { throw PairingStoreError.invalidXML }
        guard text.utf8.count <= Self.maximumFileSize else { throw PairingStoreError.tooLarge }
        return PairingXMLDocument(text: text, type: .lockdown, isConvertedToXML: converted,
                                  originalData: data, target: url, fileID: id, storeID: storeID)
    }

    func validateXML(_ text: String, for type: PairingType) throws {
        _ = try validatedXMLData(text, for: type)
    }

    /// Compare the original bytes and atomically replace only after validation and private staging succeed.
    func saveXML(_ text: String, replacing document: PairingXMLDocument) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try validatedXMLData(text, for: document.type)
        guard document.storeID == storeID,
              let target = annotationTarget(for: document.fileID), target == document.target else {
            throw PairingStoreError.xmlConflict
        }
        let current: Data
        do { current = try readBoundedData(at: target) }
        catch { throw PairingStoreError.xmlUnavailable }
        guard current == document.originalData else { throw PairingStoreError.xmlConflict }
        let staging = directory.appendingPathComponent(".pairing-edit-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #if canImport(Darwin)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            #endif
            #if os(iOS)
            try data.write(to: staging, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: staging, options: .atomic)
            #endif
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)

            // Legacy annotations use filesystem identity. Prepare the new association without deleting
            // the old one, so a failed rename still preserves the original file and its annotations.
            if document.fileID.hasPrefix("legacy-") {
                let oldAttributes = try fileManager.attributesOfItem(atPath: target.path)
                let newAttributes = try fileManager.attributesOfItem(atPath: staging.path)
                if let oldKey = annotationKey(for: target, attributes: oldAttributes),
                   let newKey = annotationKey(for: target, attributes: newAttributes), oldKey != newKey {
                    var annotations = try readAnnotations()
                    if let annotation = annotations[oldKey] {
                        annotations[newKey] = annotation
                        try writeAnnotations(annotations)
                    }
                }
            }
            guard !isSymbolicLink(directory), !isSymbolicLink(target),
                  try readBoundedData(at: target) == document.originalData else { throw PairingStoreError.xmlConflict }
            // POSIX rename is the final fallible step; no post-commit operation can report a false failure.
            guard rename(staging.path, target.path) == 0 else { throw PairingStoreError.storageFailed }
        } catch let error as PairingStoreError {
            throw error
        } catch { throw PairingStoreError.storageFailed }
    }

    private func validatedXMLData(_ text: String, for type: PairingType) throws -> Data {
        guard type == .lockdown else { throw PairingStoreError.unsupportedProtocol }
        guard text.utf8.count <= Self.maximumFileSize else { throw PairingStoreError.tooLarge }
        try checkXMLDeclarations(text)
        let data = Data(text.utf8)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: &format),
              format == .xml, object is [String: Any] else { throw PairingStoreError.invalidXML }
        guard lockdownDictionary(data) != nil else { throw PairingStoreError.invalidLockdown }
        return data
    }

    private func checkXMLDeclarations(_ text: String) throws {
        // Keep Apple's standard plist DOCTYPE, but reject entities, custom DTDs and internal subsets.
        // Never pass an attacker-controlled external declaration to the plist parser.
        guard text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw PairingStoreError.unsafeXML }
        let pattern = "<!DOCTYPE\\s+plist\\s+PUBLIC\\s+\"-//Apple(?: Computer)?//DTD PLIST 1\\.0//EN\"\\s+\"http://www\\.apple\\.com/DTDs/PropertyList-1\\.0\\.dtd\"\\s*>"
        let stripped = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        guard stripped.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else { throw PairingStoreError.unsafeXML }
    }

    /// Only writes a private sidecar. No plist parsing, serialization or credential mutation here.
    func updateAnnotation(for id: String, annotation: PairingFileAnnotation,
                          expected: PairingFileAnnotation) throws {
        lock.lock(); defer { lock.unlock() }
        let value = try annotation.validated()
        guard let url = annotationTarget(for: id), !isSymbolicLink(directory), !isSymbolicLink(url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { throw PairingStoreError.fileMissing }
        guard let key = annotationKey(for: url, attributes: attributes) else { throw PairingStoreError.fileMissing }
        var annotations = try readAnnotations()
        guard (annotations[key] ?? .empty) == expected else {
            throw PairingStoreError.annotationConflict
        }
        if value == .empty { annotations.removeValue(forKey: key) }
        else { annotations[key] = value }
        try writeAnnotations(annotations)
    }

    private func annotationTarget(for id: String) -> URL? {
        if let type = PairingType(rawValue: id) { return directory.appendingPathComponent(type.fileName) }
        // Never turn an externally supplied ID into a filesystem path; legacy IDs are opaque.
        return legacyIdentifiers.first(where: { $0.value == id })?.key
    }

    private func annotationKey(for url: URL, attributes: [FileAttributeKey: Any]?) -> String? {
        if let type = PairingType.allCases.first(where: { $0.fileName == url.lastPathComponent }) { return type.rawValue }
        // Do not persist legacy filenames: they can contain a device identifier.
        // Filesystem identity plus birth time also prevents labels moving when sorted aliases change.
        guard let device = attributes?[.systemNumber] as? NSNumber,
              let inode = attributes?[.systemFileNumber] as? NSNumber else { return nil }
        #if canImport(Darwin)
        guard let created = attributes?[.creationDate] as? Date else { return nil }
        return "legacy-file-\(device.uint64Value)-\(inode.uint64Value)-\(created.timeIntervalSince1970.bitPattern)"
        #else
        // swift-corelibs Foundation may expose ctime as creationDate; ctime changes on rename.
        // The iOS path above uses the actual birth time; portable regression tests use inode identity.
        return "legacy-file-\(device.uint64Value)-\(inode.uint64Value)"
        #endif
    }

    private func readAnnotations() throws -> [String: PairingFileAnnotation] {
        let url = directory.appendingPathComponent(Self.annotationsFileName)
        guard !isSymbolicLink(directory), !isSymbolicLink(url) else { throw PairingStoreError.annotationUnavailable }
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try readBoundedData(at: url)
            guard data.count <= Self.maximumAnnotationsSize else { throw PairingStoreError.annotationUnavailable }
            let annotations = try JSONDecoder().decode([String: PairingFileAnnotation].self, from: data)
            for value in annotations.values {
                guard try value.validated() == value else { throw PairingStoreError.annotationUnavailable }
            }
            return annotations
        } catch { throw PairingStoreError.annotationUnavailable }
    }

    private func writeAnnotations(_ annotations: [String: PairingFileAnnotation]) throws {
        let url = directory.appendingPathComponent(Self.annotationsFileName)
        do {
            guard !isSymbolicLink(directory), !isSymbolicLink(url) else { throw PairingStoreError.annotationUnavailable }
            let data = try JSONEncoder().encode(annotations)
            guard data.count <= Self.maximumAnnotationsSize else { throw PairingStoreError.annotationUnavailable }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #if canImport(Darwin)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            #endif
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw PairingStoreError.annotationUnavailable }
    }

    /// Validate before touching the destination; an invalid replacement preserves working credentials.
    func importLockdown(from source: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try readBoundedData(at: source)
        guard lockdownDictionary(data) != nil else { throw PairingStoreError.invalidLockdown }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard !isSymbolicLink(directory) else { throw PairingStoreError.storageFailed }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #if canImport(Darwin)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            #endif
            let destination = directory.appendingPathComponent(PairingType.lockdown.fileName)
            guard !isSymbolicLink(destination) else { throw PairingStoreError.storageFailed }
            #if os(iOS)
            // Background heartbeat can reconnect after the device locks, once it has been unlocked after boot.
            try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: destination, options: .atomic)
            #endif
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            // Filesystem and parser errors may contain paths or credential values. Never forward them.
            throw PairingStoreError.storageFailed
        }
    }

    func delete(_ type: PairingType) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isSymbolicLink(directory) else { throw PairingStoreError.storageFailed }
        let url = directory.appendingPathComponent(type.fileName)
        do {
            if fileManager.fileExists(atPath: url.path) || isSymbolicLink(url) {
                var annotations = try readAnnotations()
                if annotations.removeValue(forKey: type.rawValue) != nil { try writeAnnotations(annotations) }
                try fileManager.removeItem(at: url)
            }
        } catch {
            throw PairingStoreError.storageFailed
        }
    }

    func reset() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            if fileManager.fileExists(atPath: directory.path) || isSymbolicLink(directory) {
                try fileManager.removeItem(at: directory)
            }
            defaults.removeObject(forKey: Self.preferenceKey)
            legacyIdentifiers.removeAll()
        } catch {
            throw PairingStoreError.storageFailed
        }
    }

    private func selectedLockdownURL() -> URL? {
        let canonical = directory.appendingPathComponent(PairingType.lockdown.fileName)
        return ([canonical] + legacyURLs()).first { url in
            guard let data = try? readBoundedData(at: url) else { return false }
            return lockdownDictionary(data) != nil
        }
    }

    private func validRemoteURL() -> URL? {
        let url = directory.appendingPathComponent(PairingType.remote.fileName)
        guard let data = try? readBoundedData(at: url), remoteDictionary(data) != nil else { return nil }
        return url
    }

    private func legacyURLs() -> [URL] {
        guard !isSymbolicLink(directory),
              let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let reserved = Set(PairingType.allCases.map(\.fileName))
        return urls.filter { $0.pathExtension.lowercased() == "plist" && !reserved.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func readBoundedData(at url: URL) throws -> Data {
        guard !isSymbolicLink(directory), !isSymbolicLink(url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { throw PairingStoreError.unreadable }
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value <= Int64(Self.maximumFileSize) else { throw PairingStoreError.tooLarge }
        // Bound the read too: the source can grow after the metadata check.
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
            guard data.count <= Self.maximumFileSize else { throw PairingStoreError.tooLarge }
            return data
        } catch let error as PairingStoreError {
            throw error
        } catch {
            throw PairingStoreError.unreadable
        }
    }

    private func lockdownDictionary(_ data: Data) -> [String: Any]? {
        guard let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        // Structural checks only, NOT cryptographic or device-trust verification. Rust remains authoritative.
        for key in ["HostID", "SystemBUID"] {
            guard let value = dictionary[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        for key in ["HostPrivateKey", "HostCertificate", "RootCertificate", "DeviceCertificate"] {
            if let value = dictionary[key] as? Data, !value.isEmpty { continue }
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return nil
        }
        return dictionary
    }

    /// Mirrors the pinned Rust plist structure without cryptographic key/trust validation.
    private func remoteDictionary(_ data: Data) -> [String: Any]? {
        guard let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty,
              dictionary["alt_irk"] == nil || ((dictionary["alt_irk"] as? Data)?.count == 16),
              (dictionary["generated_by"] as? String) != "idevice" else { return nil }
        return dictionary
    }

    private func info(at url: URL, type: PairingType, displayName: String, id: String, selected: URL?,
                      annotations: [String: PairingFileAnnotation]?) -> PairingFileInfo {
        let installed = fileManager.fileExists(atPath: url.path)
        let safeFile = !isSymbolicLink(directory) && !isSymbolicLink(url)
        let attributes = safeFile ? try? fileManager.attributesOfItem(atPath: url.path) : nil
        let dictionary: [String: Any]?
        if let data = try? readBoundedData(at: url) {
            dictionary = type == .lockdown ? lockdownDictionary(data) : remoteDictionary(data)
        } else {
            dictionary = nil
        }
        let key = annotationKey(for: url, attributes: attributes)
        return PairingFileInfo(id: id, type: type, fileName: displayName, isInstalled: installed,
                               isStructurallyValid: dictionary != nil, isSelected: selected == url,
                               fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
                               dateCreated: attributes?[.creationDate] as? Date,
                               dateModified: attributes?[.modificationDate] as? Date,
                               presentSensitiveFields: Self.sensitiveKeys(for: type).filter { dictionary?[$0] != nil },
                               annotation: key.flatMap { key in annotations.map { $0[key] ?? .empty } },
                               canEditAnnotation: installed && safeFile && annotations != nil && key != nil &&
                                   attributes?[.type] as? FileAttributeType == .typeRegular)
    }
}
