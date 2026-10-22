import Foundation
import SideSign
#if EILI_ON_DEVICE_ANISETTE
import AnisetteKit
#endif

/// Remote remains the default. Local mode never silently sends data to a remote provider.
enum EiliAnisetteMode: String, CaseIterable, Identifiable {
    case remote, onDevice
    var id: String { rawValue }
    static let preferenceKey = "eilistore.anisette.mode"
    static let sessionKey = "eilistore.auth.anisette.mode"
    static var savedSessionMode: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: sessionKey) ?? "") ?? .remote
    }
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .remote
    }
    static var localBuildAvailable: Bool {
        #if EILI_ON_DEVICE_ANISETTE
        return true
        #else
        return false
        #endif
    }
}

enum EiliAnisetteLibraryStatus: Equatable, Sendable {
    case engineUnavailable, missing, invalid, present
}
enum EiliAnisetteError: LocalizedError {
    case localBuildRequired, missingLibraries, invalidLibraries, invalidHeaders, storageFailed, logoutRequired
    var errorDescription: String? {
        switch self {
        case .localBuildRequired: return "此版本未包含本機 Anisette，請使用本機相容性建置，或切回遠端模式。"
        case .missingLibraries: return "請先匯入 libCoreADI.so 與 libstoreservicescore.so（ARM64）。"
        case .invalidLibraries: return "必須同時選取兩個指定名稱的 ARM64 ELF 函式庫；原有資料未變更。"
        case .invalidHeaders: return "本機 Anisette 回傳不完整，未進行 Apple 登入。"
        case .storageFailed: return "無法安全保存本機 Anisette 資料，請重試。"
        case .logoutRequired: return "請先登出本機 Anisette 帳號，再匯入或重設本機資料。"
        }
    }
}

actor EiliAnisetteService {
    static let shared = EiliAnisetteService()
    private static let localIdentifierKey = "eilistore.anisette.local.identifier"
    private static let localBlobKey = "eilistore.anisette.local.adiblob"
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    #if EILI_ON_DEVICE_ANISETTE
    private var localClient: AnisetteClient?
    #endif

    // Actor methods re-enter at await: explicitly serialize provisioning, imports and resets.
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EiliStore/OnDeviceAnisette", isDirectory: true)
    }
    private var libraries: URL { root.appendingPathComponent("Libraries", isDirectory: true) }
    private let libraryNames = ["libCoreADI.so", "libstoreservicescore.so"]

    /// Only inspect local file metadata and ELF headers; never initialize a provider or identity.
    func localLibraryStatus() -> EiliAnisetteLibraryStatus {
        #if EILI_ON_DEVICE_ANISETTE
        let fm = FileManager.default
        let files = libraryNames.map { libraries.appendingPathComponent($0, isDirectory: false) }
        guard files.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return .missing }
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 64, size <= 64 * 1024 * 1024 else {
                return .invalid
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .invalid }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 64),
                  Self.validLibrary(header) else { return .invalid }
        }
        return .present
        #else
        return .engineUnavailable
        #endif
    }

    func fetch(remoteIdentifier: UUID, remoteBlob: Data?, servers: [URL],
               mode: EiliAnisetteMode = .selected) async throws -> SideSign.AnisetteData {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        switch mode {
        case .remote:
            let urls = servers.isEmpty ? [URL(string: "https://ani.sidestore.zip")!] : servers
            let (data, blob) = try await SideSign.AnisetteDataManager.shared.fetchAnisetteDataWithFailover(
                servers: urls, identifier: remoteIdentifier, existingAdiBlob: remoteBlob)
            try Task.checkCancellation()
            if let blob { KeychainHelper.save(blob, forKey: "paxstore.anisette.adiblob") }
            return data
        case .onDevice:
            return try await fetchLocal()
        }
    }

    private func fetchLocal() async throws -> SideSign.AnisetteData {
        #if EILI_ON_DEVICE_ANISETTE
        guard libraryNames.allSatisfy({ FileManager.default.fileExists(atPath: libraries.appendingPathComponent($0).path) }) else {
            throw EiliAnisetteError.missingLibraries
        }
        let identifier: UUID
        if let stored = KeychainHelper.loadString(forKey: Self.localIdentifierKey), let uuid = UUID(uuidString: stored) {
            identifier = uuid
        } else {
            identifier = UUID()
            guard KeychainHelper.saveString(identifier.uuidString, forKey: Self.localIdentifierKey) else {
                throw EiliAnisetteError.storageFailed
            }
        }
        if localClient == nil {
            let directory = libraries
            let provisioning = root.appendingPathComponent("Provisioning", isDirectory: true)
            try FileManager.default.createDirectory(at: provisioning, withIntermediateDirectories: true)
            AnisetteKitLogging.setLogging(false)
            localClient = try AnisetteClient(provisioningDir: provisioning,
                provider: UnicornAnisetteDataProvider(), libraryDirectoryResolver: { directory })
        }
        guard let client = localClient else { throw EiliAnisetteError.missingLibraries }
        let (headers, blob) = try await client.getAnisetteData(identifier: identifier,
            storage: .memory(existingBlob: KeychainHelper.load(forKey: Self.localBlobKey)))
        // Save a provisioned identity before honouring cancellation, never log its payload.
        if let blob, !KeychainHelper.save(blob, forKey: Self.localBlobKey) {
            throw EiliAnisetteError.storageFailed
        }
        try Task.checkCancellation()
        return try Self.convertHeaders(headers)
        #else
        throw EiliAnisetteError.localBuildRequired
        #endif
    }

    static func convertHeaders(_ headers: [String: String]) throws -> SideSign.AnisetteData {
        let names = ["X-Apple-I-MD-M", "X-Apple-I-MD", "X-Apple-I-MD-LU", "X-Apple-I-MD-RINFO",
                     "X-Mme-Device-Id", "X-Apple-I-SRL-NO", "X-Mme-Client-Info", "User-Agent",
                     "X-Apple-I-Client-Time", "X-Apple-Locale", "X-Apple-I-TimeZone"]
        let values = names.map { name in headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? "" }
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EiliAnisetteError.invalidHeaders
        }
        return SideSign.AnisetteData(machineID: values[0], oneTimePassword: values[1], localUserID: values[2],
            routingInfo: values[3], deviceID: values[4], serialNumber: values[5], clientInfo: values[6],
            userAgent: values[7], clientTime: values[8], locale: values[9], timeZone: values[10])
    }

    /// Validate ELF64 little-endian AArch64 shared objects before replacing anything.
    static func validLibrary(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(64))
        return bytes.count == 64 && Array(bytes[0..<4]) == [0x7f, 0x45, 0x4c, 0x46]
            && bytes[4] == 2 && bytes[5] == 1 && bytes[6] == 1
            && bytes[16] == 3 && bytes[17] == 0 && bytes[18] == 183 && bytes[19] == 0
    }

    func importLibraries(_ urls: [URL]) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard EiliAnisetteMode.localBuildAvailable else { throw EiliAnisetteError.localBuildRequired }
        guard !hasActiveLocalSession else { throw EiliAnisetteError.logoutRequired }
        guard urls.count == 2, Set(urls.map(\.lastPathComponent)) == Set(libraryNames) else {
            throw EiliAnisetteError.invalidLibraries
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let backup = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for url in urls {
            #if os(iOS)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            #endif
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 64 && size <= 64 * 1024 * 1024 else { throw EiliAnisetteError.invalidLibraries }
            let data = try Data(contentsOf: url)
            guard Self.validLibrary(data) else { throw EiliAnisetteError.invalidLibraries }
            try data.write(to: staging.appendingPathComponent(url.lastPathComponent), options: .atomic)
        }
        try Task.checkCancellation()
        let hadLibraries = fm.fileExists(atPath: libraries.path)
        if hadLibraries { try fm.moveItem(at: libraries, to: backup) }
        do { try fm.moveItem(at: staging, to: libraries) }
        catch {
            if hadLibraries { try? fm.moveItem(at: backup, to: libraries) }
            throw error
        }
        if hadLibraries { try? fm.removeItem(at: backup) }
        #if EILI_ON_DEVICE_ANISETTE
        localClient = nil
        resetLocalAnisetteEngine()
        #endif
    }

    func resetLocal() async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard !hasActiveLocalSession else { throw EiliAnisetteError.logoutRequired }
        let provisioning = root.appendingPathComponent("Provisioning", isDirectory: true)
        if FileManager.default.fileExists(atPath: provisioning.path) {
            try FileManager.default.removeItem(at: provisioning)
        }
        KeychainHelper.delete(forKey: Self.localIdentifierKey)
        KeychainHelper.delete(forKey: Self.localBlobKey)
        #if EILI_ON_DEVICE_ANISETTE
        localClient = nil
        resetLocalAnisetteEngine()
        #endif
    }

    private var hasActiveLocalSession: Bool {
        EiliAnisetteMode.savedSessionMode == .onDevice
            && KeychainHelper.load(forKey: "paxstore.auth.session") != nil
    }
}
