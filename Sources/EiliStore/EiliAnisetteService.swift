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
    case incompatible(String)
}
enum EiliAnisetteError: LocalizedError {
    case localBuildRequired, missingLibraries, invalidLibraries, invalidHeaders, storageFailed, logoutRequired
    case incompatibleLibraries(String)
    case libraryRecoveryRequired(String)
    var errorDescription: String? {
        switch self {
        case .localBuildRequired: return "此版本未包含本機 Anisette，請使用本機相容性建置，或切回遠端模式。"
        case .missingLibraries: return "ADI 函式庫尚未完整匯入；請選取同一版本的完整舊版兩庫或新版五庫（ARM64）。"
        case .invalidLibraries: return "請完整選取舊版兩庫或新版五庫的指定 ARM64 ELF 檔案，勿混用或改名；原有資料未變更。"
        case .incompatibleLibraries(let reason): return reason
        case .libraryRecoveryRequired(let backup): return "匯入及自動回復均失敗；原函式庫仍保留於 \(backup) 備份資料夾，未刪除。請保留備份，不要將此次匯入視為成功。"
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
    private static let localRoutingInfoKey = "eilistore.anisette.local.routinginfo"
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

    /// Both layouts require bounded ELF metadata, dependencies and symbol preflight.
    /// Neither path initializes a VM/provider, creates an identity, or contacts Apple.
    func localLibraryStatus() -> EiliAnisetteLibraryStatus {
        #if EILI_ON_DEVICE_ANISETTE
        let fm = FileManager.default
        guard let profile = ADILibraryProfile.detected(in: libraries) else { return .invalid }
        let files = profile.filenames.map { libraries.appendingPathComponent($0, isDirectory: false) }
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
        guard let report = try? ADILibraryCompatibility.read(directory: libraries, profile: profile) else { return .invalid }
        if !report.runtimeAdapterAvailable || report.hasStaticBlockers { return .incompatible(report.summary) }
        return .present
        #else
        return .engineUnavailable
        #endif
    }

    func fetch(remoteIdentifier: UUID, remoteBlob: Data?, servers: [URL],
               mode: EiliAnisetteMode = .selected,
               configuration: EiliAnisetteClientConfiguration = .empty) async throws -> SideSign.AnisetteData {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let configuration = try configuration.validated()
        switch mode {
        case .remote:
            let urls = servers.isEmpty ? [URL(string: "https://ani.sidestore.zip")!] : servers
            let (data, blob) = try await SideSign.AnisetteDataManager.shared.fetchAnisetteDataWithFailover(
                servers: urls, identifier: remoteIdentifier, existingAdiBlob: remoteBlob,
                headers: .init(rawHeaders: configuration.requestHeaderOverrides))
            try Task.checkCancellation()
            if let blob { KeychainHelper.save(blob, forKey: "paxstore.anisette.adiblob") }
            // SideSign may reuse a provider cache; reapply metadata so a saved
            // override is honored even when a cached Anisette result is returned.
            return configuration.applying(to: data)
        case .onDevice:
            return try await fetchLocal(configuration: configuration)
        }
    }

    private func fetchLocal(configuration: EiliAnisetteClientConfiguration) async throws -> SideSign.AnisetteData {
        #if EILI_ON_DEVICE_ANISETTE
        switch localLibraryStatus() {
        case .engineUnavailable: throw EiliAnisetteError.localBuildRequired
        case .missing: throw EiliAnisetteError.missingLibraries
        case .invalid: throw EiliAnisetteError.invalidLibraries
        case .incompatible(let reason): throw EiliAnisetteError.incompatibleLibraries(reason)
        case .present: break
        }
        guard let profile = ADILibraryProfile.detected(in: libraries) else { throw EiliAnisetteError.invalidLibraries }
        if localClient == nil && profile == .legacy {
            let entry = libraries.appendingPathComponent("libstoreservicescore.so")
            if let data = try? ADILibraryCompatibility.readLibrary(entry),
               let metadata = try? ADIELFMetadata.parse(data), metadata.soname == "libstoreapi.so" {
                throw EiliAnisetteError.incompatibleLibraries("新版 libstoreapi.so 不可改名冒充舊版函式庫；請匯入原名五庫並查看相容性提示。")
            }
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
                requiredLibraries: profile.filenames,
                provider: UnicornAnisetteDataProvider(), libraryDirectoryResolver: { directory })
        }
        guard let client = localClient else { throw EiliAnisetteError.missingLibraries }
        var requestHeaders = configuration.requestHeaderOverrides
        let explicitRoutingOverride = requestHeaders.keys.contains { $0.caseInsensitiveCompare("X-Apple-I-MD-RINFO") == .orderedSame }
        if !explicitRoutingOverride, let routingInfo = KeychainHelper.loadString(forKey: Self.localRoutingInfoKey) {
            requestHeaders["X-Apple-I-MD-RINFO"] = routingInfo
        }
        let (headers, blob) = try await client.getAnisetteData(identifier: identifier,
            storage: .memory(existingBlob: KeychainHelper.load(forKey: Self.localBlobKey)),
            headers: .init(rawHeaders: requestHeaders))
        // Save a provisioned identity before honouring cancellation, never log its payload.
        if let blob, !KeychainHelper.save(blob, forKey: Self.localBlobKey) {
            throw EiliAnisetteError.storageFailed
        }
        let returnedRoutingInfo = headers.first { $0.key.caseInsensitiveCompare("X-Apple-I-MD-RINFO") == .orderedSame }?.value
        if (blob != nil || !explicitRoutingOverride), let returnedRoutingInfo,
           !KeychainHelper.saveString(returnedRoutingInfo, forKey: Self.localRoutingInfoKey) {
            throw EiliAnisetteError.storageFailed
        }
        try Task.checkCancellation()
        // The native provider's persisted routing info can take precedence over
        // request headers internally. The Apple-bound metadata still honors the
        // explicit override without modifying stored provisioning state.
        return configuration.applying(to: try Self.convertHeaders(headers))
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

    @discardableResult
    func importLibraries(_ urls: [URL]) async throws -> EiliAnisetteLibraryStatus {
        await acquire()
        defer { release() }
        return try installLibraries(urls)
    }

    /// Explicit opt-in only: never called by login, status checks, or remote mode.
    /// The same gate covers network, validation and replacement so a session cannot
    /// begin provisioning while its libraries are being replaced.
    @discardableResult
    func downloadLibraries() async throws -> EiliAnisetteLibraryStatus {
        try await downloadLibraries(using: { directory in
            try await ADIRuntimeLibraryDownloader().stageLibraries(in: directory)
        })
    }

    @discardableResult
    func downloadLibraries(using stage: @Sendable (URL) async throws -> [URL]) async throws -> EiliAnisetteLibraryStatus {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard EiliAnisetteMode.localBuildAvailable else { throw EiliAnisetteError.localBuildRequired }
        guard !hasActiveLocalSession else { throw EiliAnisetteError.logoutRequired }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let download = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: download, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: download) }
        let urls = try await stage(download)
        try Task.checkCancellation()
        // Reuse the import transaction, including ABI gating and rollback. No
        // preference, provisioning identity or remote blob is changed by download.
        return try installLibraries(urls)
    }

    private func installLibraries(_ urls: [URL]) throws -> EiliAnisetteLibraryStatus {
        try Task.checkCancellation()
        guard EiliAnisetteMode.localBuildAvailable else { throw EiliAnisetteError.localBuildRequired }
        guard !hasActiveLocalSession else { throw EiliAnisetteError.logoutRequired }
        guard let profile = ADILibraryProfile.selected(urls.map(\.lastPathComponent)) else {
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
            let data: Data
            do { data = try ADILibraryCompatibility.readLibrary(url) }
            catch { throw EiliAnisetteError.invalidLibraries }
            guard Self.validLibrary(data) else { throw EiliAnisetteError.invalidLibraries }
            if profile == .legacy, let metadata = try? ADIELFMetadata.parse(data), metadata.soname == "libstoreapi.so" {
                throw EiliAnisetteError.incompatibleLibraries("新版 libstoreapi.so 不可改名冒充 libstoreservicescore.so；舊檔案未變更。")
            }
            try data.write(to: staging.appendingPathComponent(url.lastPathComponent), options: .atomic)
        }
        let report: ADILibraryCompatibility
        do { report = try ADILibraryCompatibility.read(directory: staging, profile: profile) }
        catch { throw EiliAnisetteError.invalidLibraries }
        let status: EiliAnisetteLibraryStatus = report.runtimeAdapterAvailable && !report.hasStaticBlockers
            ? .present : .incompatible(report.summary)
        // Keep manual diagnostic imports when there is no usable set, but never
        // replace an existing preflight-passing set with an incompatible one.
        if case .incompatible = status, localLibraryStatus() == .present {
            throw EiliAnisetteError.incompatibleLibraries(report.summary + " 原有通過檢查的函式庫已保留，未替換。")
        }
        try Task.checkCancellation()
        let hadLibraries = fm.fileExists(atPath: libraries.path)
        if hadLibraries { try fm.moveItem(at: libraries, to: backup) }
        do { try fm.moveItem(at: staging, to: libraries) }
        catch {
            if hadLibraries {
                do { try fm.moveItem(at: backup, to: libraries) }
                catch { throw EiliAnisetteError.libraryRecoveryRequired(backup.lastPathComponent) }
            }
            throw error
        }
        if hadLibraries { try? fm.removeItem(at: backup) }
        #if EILI_ON_DEVICE_ANISETTE
        localClient = nil
        resetLocalAnisetteEngine()
        #endif
        return status
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
        KeychainHelper.delete(forKey: Self.localRoutingInfoKey)
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
