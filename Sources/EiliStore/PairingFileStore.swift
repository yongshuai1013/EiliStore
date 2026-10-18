import Foundation

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
}

enum PairingStoreError: Error, LocalizedError {
    case invalidLockdown, unreadable, tooLarge, storageFailed, unsupportedProtocol

    var errorDescription: String? {
        switch self {
        case .invalidLockdown: return "這不是完整的 Lockdown 配對檔。請重新產生後匯入；現有檔案未被替換。"
        case .unreadable: return "無法讀取配對檔。請確認檔案可用並重試。"
        case .tooLarge: return "配對檔過大，已拒絕匯入。"
        case .storageFailed: return "無法更新配對檔儲存空間，請重新整理後確認狀態。"
        case .unsupportedProtocol: return "目前的連線引擎只支援 Lockdown，不能匯入或啟用 Remote Pairing。"
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

    init(directory: URL? = nil, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.directory = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PairingFiles", isDirectory: true)
        self.defaults = defaults
        self.fileManager = fileManager
    }

    var preferredProtocol: PairingType? {
        lock.lock(); defer { lock.unlock() }
        // An unsupported/stale preference must not change the transport.
        return defaults.string(forKey: Self.preferenceKey) == PairingType.lockdown.rawValue ? .lockdown : nil
    }

    func setPreferredProtocol(_ type: PairingType?) throws {
        lock.lock(); defer { lock.unlock() }
        guard type != .remote else { throw PairingStoreError.unsupportedProtocol }
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

    func inventory() -> [PairingFileInfo] {
        lock.lock(); defer { lock.unlock() }
        let selected = selectedLockdownURL()
        let canonical = PairingType.allCases.map { type in
            info(at: directory.appendingPathComponent(type.fileName), type: type,
                 displayName: type.fileName, id: type.rawValue, selected: selected)
        }
        // Legacy names can contain a device identifier. Use numbered aliases, never the original name.
        let legacy = legacyURLs().enumerated().map { index, url in
            info(at: url, type: .lockdown, displayName: "舊版配對檔 \(index + 1)",
                 id: "legacy-\(index)", selected: selected)
        }
        return canonical + legacy
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

    private func info(at url: URL, type: PairingType, displayName: String, id: String, selected: URL?) -> PairingFileInfo {
        let installed = fileManager.fileExists(atPath: url.path)
        let safeFile = !isSymbolicLink(directory) && !isSymbolicLink(url)
        let attributes = safeFile ? try? fileManager.attributesOfItem(atPath: url.path) : nil
        let dictionary: [String: Any]?
        if type == .lockdown, let data = try? readBoundedData(at: url) {
            dictionary = lockdownDictionary(data)
        } else {
            dictionary = nil
        }
        let sensitiveKeys = ["SystemBUID", "HostID", "UDID", "HardwareUDID", "WiFiMACAddress", "WifiMAC",
                             "HostPrivateKey", "RootPrivateKey", "HostCertificate", "RootCertificate", "DeviceCertificate", "EscrowBag"]
        return PairingFileInfo(id: id, type: type, fileName: displayName, isInstalled: installed,
                               isStructurallyValid: dictionary != nil, isSelected: selected == url,
                               fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
                               dateCreated: attributes?[.creationDate] as? Date,
                               dateModified: attributes?[.modificationDate] as? Date,
                               presentSensitiveFields: sensitiveKeys.filter { dictionary?[$0] != nil })
    }
}
