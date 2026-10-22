import Foundation
import SideSign
#if EILI_ON_DEVICE_ANISETTE
import AnisetteKit
#endif

private final class FakeKeychainStore: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Data] = [:]
    func get(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func put(_ data: Data, _ key: String) { lock.lock(); defer { lock.unlock() }; values[key] = data }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
}
private let fakeKeychain = FakeKeychainStore()
enum KeychainHelper {
    @discardableResult static func save(_ data: Data, forKey key: String) -> Bool { fakeKeychain.put(data, key); return true }
    static func load(forKey key: String) -> Data? { fakeKeychain.get(key) }
    @discardableResult static func saveString(_ value: String, forKey key: String) -> Bool { save(Data(value.utf8), forKey: key) }
    static func loadString(forKey key: String) -> String? { load(forKey: key).flatMap { String(data: $0, encoding: .utf8) } }
    @discardableResult static func delete(forKey key: String) -> Bool { fakeKeychain.remove(key); return true }
}

@main struct EiliAnisetteServiceTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() async throws {
        let manager = SideSign.AnisetteDataManager.shared
        let originalPreference = UserDefaults.standard.object(forKey: EiliAnisetteMode.preferenceKey)
        let originalSession = UserDefaults.standard.object(forKey: EiliAnisetteMode.sessionKey)
        defer {
            if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: EiliAnisetteMode.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.preferenceKey) }
            if let originalSession { UserDefaults.standard.set(originalSession, forKey: EiliAnisetteMode.sessionKey) }
            else { UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey) }
        }
        await manager.reset()
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.preferenceKey)
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)
        check(EiliAnisetteMode.allCases == [.remote, .onDevice], "mode cases must include remote and on-device")
        #if EILI_ON_DEVICE_ANISETTE
        check(EiliAnisetteMode.localBuildAvailable, "local build flag should report local availability")
        #else
        check(!EiliAnisetteMode.localBuildAvailable, "remote build should report local unavailable")
        #endif
        check(EiliAnisetteMode.selected == .remote, "preference default must be remote")
        let svc = EiliAnisetteService(), id = UUID(), blob = Data([1, 2]), responseBlob = Data([9, 8])
        let urls = [URL(string: "https://first.invalid")!, URL(string: "https://second.invalid")!]
        await manager.reset()
        #if EILI_ON_DEVICE_ANISETTE
        FakeAnisetteKitControl.reset()
        #endif
        _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: blob, servers: urls)
        var implicitCalls = await manager.calls
        check(implicitCalls == 1, "cold-boot implicit fetch must route remote")
        #if EILI_ON_DEVICE_ANISETTE
        check(FakeAnisetteKitControl.calls == 0, "cold-boot implicit fetch called local provider")
        #endif
        await manager.reset()
        UserDefaults.standard.set("nonsense", forKey: EiliAnisetteMode.preferenceKey)
        check(EiliAnisetteMode.selected == .remote, "unknown preference must default remote")
        _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: blob, servers: urls)
        implicitCalls = await manager.calls
        check(implicitCalls == 1, "unknown preference implicit fetch must route remote")
        #if EILI_ON_DEVICE_ANISETTE
        check(FakeAnisetteKitControl.calls == 0, "unknown preference implicit fetch called local provider")
        #endif
        UserDefaults.standard.set("nonsense", forKey: EiliAnisetteMode.sessionKey)
        check(EiliAnisetteMode.savedSessionMode == .remote, "unknown session mode must default remote")
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.sessionKey)
        check(EiliAnisetteMode.savedSessionMode == .onDevice, "session mode mapping")
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)

        await manager.reset()
        _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: blob, servers: urls, mode: .remote)
        let callCount = await manager.calls, gotServers = await manager.lastServers, gotID = await manager.lastIdentifier, gotBlob = await manager.lastBlob
        check(callCount == 1 && gotServers == urls && gotID == id && gotBlob == blob, "remote routing parameters")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == nil, "unexpected blob persisted")
        await manager.reset()
        await manager.setResponseForTests(data: nil, blob: responseBlob)
        _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: [], mode: .remote)
        let defaultServers = await manager.lastServers
        check(defaultServers == [URL(string: "https://ani.sidestore.zip")!], "default failover URL")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == responseBlob, "remote blob save")

        await manager.reset()
        if !EiliAnisetteMode.localBuildAvailable {
            check(await svc.localLibraryStatus() == .engineUnavailable, "disabled engine status")
            do { _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice); fatalError("expected localBuildRequired") }
            catch EiliAnisetteError.localBuildRequired {}
            let localCalls = await manager.calls; check(localCalls == 0, "unavailable local mode called remote")
            do {
                _ = try await svc.downloadLibraries(using: { _ in fatalError("disabled build started download") })
                fatalError("disabled build allowed download")
            } catch EiliAnisetteError.localBuildRequired {}
        }

        #if EILI_ON_DEVICE_ANISETTE
        let fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("anisette-elf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        let elfFiles = try ELFLibraryFixtures.write(to: fixtureDir)
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EiliStore/OnDeviceAnisette", isDirectory: true)
        let backupURL = supportRoot.deletingLastPathComponent().appendingPathComponent("OnDeviceAnisette-test-backup-\(UUID().uuidString)")
        let supportRootExisted = FileManager.default.fileExists(atPath: supportRoot.path)
        if supportRootExisted { try FileManager.default.copyItem(at: supportRoot, to: backupURL) }
        let originalLocalBlob = KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob")
        let originalRemoteBlob = KeychainHelper.load(forKey: "paxstore.anisette.adiblob")
        let originalAuthSession = KeychainHelper.load(forKey: "paxstore.auth.session")
        defer {
            try? FileManager.default.removeItem(at: supportRoot)
            if supportRootExisted { try? FileManager.default.moveItem(at: backupURL, to: supportRoot) }
            else { try? FileManager.default.removeItem(at: backupURL) }
            for (key, value) in [("eilistore.anisette.local.adiblob", originalLocalBlob), ("paxstore.anisette.adiblob", originalRemoteBlob), ("paxstore.auth.session", originalAuthSession)] {
                if let value { KeychainHelper.save(value, forKey: key) } else { KeychainHelper.delete(forKey: key) }
            }
        }
        try? FileManager.default.removeItem(at: supportRoot)
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.preferenceKey)
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.sessionKey)
        let localStatusBlob = Data([0x91, 0x92])
        KeychainHelper.save(localStatusBlob, forKey: "eilistore.anisette.local.adiblob")
        KeychainHelper.save(Data([0x93]), forKey: "paxstore.anisette.adiblob")
        KeychainHelper.save(Data([0x94]), forKey: "paxstore.auth.session")
        FakeAnisetteKitControl.reset()
        check(await svc.localLibraryStatus() == .missing, "missing library status")
        check(!FileManager.default.fileExists(atPath: supportRoot.path), "status created missing library directory")
        check(UserDefaults.standard.string(forKey: EiliAnisetteMode.preferenceKey) == "onDevice" && UserDefaults.standard.string(forKey: EiliAnisetteMode.sessionKey) == "onDevice", "status changed saved mode")
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob") == localStatusBlob && KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == Data([0x93]) && KeychainHelper.load(forKey: "paxstore.auth.session") == Data([0x94]), "status changed keychain state")
        check(FakeAnisetteKitControl.calls == 0 && FakeAnisetteKitControl.resetCount == 0, "status called local provider")
        KeychainHelper.delete(forKey: "paxstore.auth.session")
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)
        try FileManager.default.createDirectory(at: supportRoot.appendingPathComponent("Libraries", isDirectory: true), withIntermediateDirectories: true)
        let libraryDirectory = supportRoot.appendingPathComponent("Libraries", isDirectory: true)
        try Data(repeating: 0, count: 128).write(to: libraryDirectory.appendingPathComponent("libCoreADI.so"))
        try Data(repeating: 1, count: 128).write(to: libraryDirectory.appendingPathComponent("libstoreservicescore.so"))
        check(await svc.localLibraryStatus() == .invalid, "invalid ELF library status")
        let validFixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("anisette-valid-elf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: validFixtureDir) }
        let validFixtures = try ELFLibraryFixtures.write(to: validFixtureDir)
        for source in validFixtures { try Data(contentsOf: source).write(to: libraryDirectory.appendingPathComponent(source.lastPathComponent), options: .atomic) }
        check(await svc.localLibraryStatus() == .present, "valid ELF library status")
        check(FakeAnisetteKitControl.calls == 0 && FakeAnisetteKitControl.resetCount == 0, "status touched local provider")
        let coreFile = libraryDirectory.appendingPathComponent("libCoreADI.so")
        let servicesFile = libraryDirectory.appendingPathComponent("libstoreservicescore.so")
        let validCore = try Data(contentsOf: coreFile)
        let validServices = try Data(contentsOf: servicesFile)
        try FileManager.default.removeItem(at: coreFile)
        try FileManager.default.createDirectory(at: coreFile, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: servicesFile)
        check(await svc.localLibraryStatus() == .missing, "missing file must take priority over invalid metadata")
        try validServices.write(to: servicesFile)
        check(await svc.localLibraryStatus() == .invalid, "directory accepted as ADI library")
        try FileManager.default.removeItem(at: coreFile)
        try FileManager.default.createSymbolicLink(at: coreFile, withDestinationURL: validFixtures.first!)
        check(await svc.localLibraryStatus() == .invalid, "symbolic link accepted as ADI library")
        try FileManager.default.removeItem(at: coreFile)
        try Data(validCore.prefix(64)).write(to: coreFile)
        check(await svc.localLibraryStatus() == .invalid, "header-only file accepted as complete library")
        let oversized = try FileHandle(forWritingTo: coreFile)
        try oversized.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try oversized.close()
        check(await svc.localLibraryStatus() == .invalid, "oversized file accepted as ADI library")
        try validCore.write(to: coreFile, options: .atomic)
        check(await svc.localLibraryStatus() == .present, "status did not recover after valid files restored")
        check(FakeAnisetteKitControl.calls == 0 && FakeAnisetteKitControl.resetCount == 0, "read-only status initialized or reset provider")
        print("PASS: read-only ADI status (missing/invalid/present, file metadata and bounded ELF headers, no provider/reset calls)")
        try FileManager.default.removeItem(at: libraryDirectory)
        let remoteCallsBeforeMissing = await manager.calls
        do { _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice); fatalError("expected missing local libraries") }
        catch EiliAnisetteError.missingLibraries {}
        check(FakeAnisetteKitControl.calls == 0, "missing libraries reached local provider")
        let remoteCallsAfterMissing = await manager.calls
        check(remoteCallsBeforeMissing == remoteCallsAfterMissing, "missing local libraries fell back to remote")
        try await svc.importLibraries(elfFiles)
        // Runtime retrieval reuses the atomic importer, never starts provisioning,
        // and leaves remote defaults/identity untouched. All payloads are synthetic.
        let downloadMode = EiliAnisetteMode.selected
        let downloadRemoteBlob = KeychainHelper.load(forKey: "paxstore.anisette.adiblob")
        FakeAnisetteKitControl.reset()
        let downloadedStatus = try await svc.downloadLibraries(using: { directory in
            try ELFLibraryFixtures.write(to: directory)
        })
        check(downloadedStatus == .present, "valid download not installed")
        check(FakeAnisetteKitControl.calls == 0 && FakeAnisetteKitControl.initializations == 0, "download initialized provider")
        check(EiliAnisetteMode.selected == downloadMode, "download changed selected mode")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == downloadRemoteBlob, "download modified remote identity")
        let coreBeforeFailedDownload = try Data(contentsOf: coreFile)
        do {
            _ = try await svc.downloadLibraries(using: { directory in
                try Data([1, 2]).write(to: directory.appendingPathComponent("partial"))
                throw ADIRuntimeLibraryDownloader.UnexpectedDownload.networkMustNotRun
            })
            fatalError("partial failed download accepted")
        } catch ADIRuntimeLibraryDownloader.UnexpectedDownload.networkMustNotRun {}
        check(try Data(contentsOf: coreFile) == coreBeforeFailedDownload, "failed download damaged cache")
        let cancelledDownload = Task {
            try await svc.downloadLibraries(using: { directory in
                let files = try ELFLibraryFixtures.write(to: directory)
                try await Task.sleep(nanoseconds: 500_000_000)
                return files
            })
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledDownload.cancel()
        do { _ = try await cancelledDownload.value; fatalError("cancelled download installed") }
        catch is CancellationError {}
        check(try Data(contentsOf: coreFile) == coreBeforeFailedDownload, "cancelled download damaged cache")
        let leftoverDownloads = try FileManager.default.contentsOfDirectory(atPath: supportRoot.path).filter { $0.hasPrefix(".download-") }
        check(leftoverDownloads.isEmpty, "temporary download payloads leaked")
        print("PASS: runtime download transaction, synthetic install, failure/cancellation cleanup and mode/identity isolation")
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.preferenceKey)
        let localResponseBlob = Data([0x10, 0x20, 0x30])
        FakeAnisetteKitControl.reset()
        FakeAnisetteKitControl.configure(blob: localResponseBlob)
        let remoteBlobBeforeLocal = Data([0xBA, 0xAD])
        KeychainHelper.save(remoteBlobBeforeLocal, forKey: "paxstore.anisette.adiblob")
        let localData = try await svc.fetch(remoteIdentifier: id, remoteBlob: blob, servers: urls)
        check(FakeAnisetteKitControl.calls == 1 && FakeAnisetteKitControl.identifier != nil, "local provider not called")
        let remoteCallsAfterImplicitLocal = await manager.calls
        check(remoteCallsAfterImplicitLocal == remoteCallsBeforeMissing, "saved on-device preference called remote")
        check(localData.machineID == "v0" && localData.oneTimePassword == "v1", "local header conversion")
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob") == localResponseBlob, "local blob persistence")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == remoteBlobBeforeLocal, "local branch modified remote blob")
        UserDefaults.standard.set("remote", forKey: EiliAnisetteMode.preferenceKey)
        FakeAnisetteKitControl.reset()
        await manager.reset()
        _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: blob, servers: urls)
        let remoteAfterSwitch = await manager.calls
        check(remoteAfterSwitch == 1 && FakeAnisetteKitControl.calls == 0, "switching saved preference to remote did not route remote exclusively")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == remoteBlobBeforeLocal, "remote switch unexpectedly replaced response blob")
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.preferenceKey)
        FakeAnisetteKitControl.reset()
        FakeAnisetteKitControl.configure(blob: Data([0x44]), delay: 100_000_000)
        let cancelledLocal = Task { try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice) }
        try await Task.sleep(nanoseconds: 20_000_000); cancelledLocal.cancel()
        do { _ = try await cancelledLocal.value; fatalError("expected local cancellation") } catch is CancellationError {}
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob") == Data([0x44]), "local blob not saved before cancellation")
        FakeAnisetteKitControl.reset(); FakeAnisetteKitControl.configure(blob: nil, throwsError: true)
        let remoteCallsBeforeError = await manager.calls
        do { _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice); fatalError("expected local error") }
        catch FakeAnisetteError.expected {}
        check(FakeAnisetteKitControl.calls == 1, "local error did not reach provider")
        let remoteCallsAfterError = await manager.calls
        check(remoteCallsBeforeError == remoteCallsAfterError, "local error fell back to remote")
        FakeAnisetteKitControl.reset()
        let remoteKeep = Data([0x77, 0x88]); KeychainHelper.save(remoteKeep, forKey: "paxstore.anisette.adiblob")
        try await svc.resetLocal()
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob") == nil, "reset retained local blob")
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.identifier") == nil, "reset retained local identifier")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == remoteKeep, "reset cleared remote blob")
        check(FakeAnisetteKitControl.resetCount >= 2, "local engine not reset after import and reset")

        let modernDir = FileManager.default.temporaryDirectory.appendingPathComponent("anisette-modern-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: modernDir) }
        try FileManager.default.createDirectory(at: modernDir, withIntermediateDirectories: true)
        var modernURLs: [URL] = []
        for name in ADILibraryProfile.modern.filenames {
            let url = modernDir.appendingPathComponent(name)
            let data = ADIElfFixture.make(soname: name,
                needed: name == "libstoreapi.so" ? Array(ADILibraryProfile.modern.filenames.dropLast()) : ["libc.so"],
                exports: name == "libstoreapi.so" ? ADILibraryCompatibility.requiredEntryPoints.sorted() : [],
                imports: name == "libCoreFP.so" ? ["pthread_create"] : [])
            try data.write(to: url); modernURLs.append(url)
        }
        FakeAnisetteKitControl.reset()
        let savedModeBeforeImport = EiliAnisetteMode.selected
        let modernSources = modernURLs
        let importedModern = try await svc.downloadLibraries(using: { directory in
            try modernSources.map { source in
                let target = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }
        })
        if case .incompatible = importedModern {} else { fatalError("modern set incorrectly marked usable") }
        check(EiliAnisetteMode.selected == savedModeBeforeImport, "modern import silently changed user preference")
        let resetCountBeforeStatus = FakeAnisetteKitControl.resetCount
        if case .incompatible = await svc.localLibraryStatus() {} else { fatalError("modern disk status lost incompatibility") }
        check(FakeAnisetteKitControl.resetCount == resetCountBeforeStatus, "modern inspection reset VM")
        let remoteBeforeBlocked = await manager.calls
        do { _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice); fatalError("unsupported modern ABI executed") }
        catch EiliAnisetteError.incompatibleLibraries {}
        check(FakeAnisetteKitControl.calls == 0 && FakeAnisetteKitControl.initializations == 0, "modern ABI initialized client or called provider")
        let remoteAfterBlocked = await manager.calls
        check(remoteAfterBlocked == remoteBeforeBlocked, "modern incompatibility silently fell back to remote")
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.identifier") == nil && KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob") == nil, "blocked modern ABI created identity")
        check(!FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Provisioning").path), "blocked modern ABI created provisioning directory")
        do { _ = try await svc.importLibraries(modernURLs + [elfFiles.first { $0.lastPathComponent == "libstoreservicescore.so" }!]); fatalError("mixed set accepted") }
        catch EiliAnisetteError.invalidLibraries {}
        let renamed = modernDir.appendingPathComponent("libstoreservicescore.so")
        try Data(contentsOf: modernDir.appendingPathComponent("libstoreapi.so")).write(to: renamed)
        do { _ = try await svc.importLibraries([modernDir.appendingPathComponent("libCoreADI.so"), renamed]); fatalError("renamed libstoreapi accepted") }
        catch EiliAnisetteError.incompatibleLibraries {}
        check(FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Libraries/libstoreapi.so").path), "failed import replaced previous set")
        try FileManager.default.removeItem(at: supportRoot.appendingPathComponent("Libraries/libCoreFP.so"))
        check(await svc.localLibraryStatus() == .missing, "incomplete modern set not reported missing")
        try await svc.importLibraries(modernURLs)
        UserDefaults.standard.set("remote", forKey: EiliAnisetteMode.preferenceKey)
        await manager.reset()
        _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls)
        let remoteWithModernFiles = await manager.calls
        check(remoteWithModernFiles == 1 && FakeAnisetteKitControl.calls == 0, "saved modern set broke remote routing")
        try await svc.importLibraries(elfFiles)
        check(await svc.localLibraryStatus() == .present, "legacy set could not be restored")
        check(!FileManager.default.fileExists(atPath: supportRoot.appendingPathComponent("Libraries/libstoreapi.so").path), "legacy restore left stale modern entry")
        print("PASS: modern five-library import/diagnostics, no VM/provider/identity or silent fallback, rename/mix rejection and legacy restore")
        try? FileManager.default.removeItem(at: supportRoot)
        #endif

        let validHeaders = ["X-apple-i-md-m":"m", "x-APPLE-I-MD":"otp", "x-apple-i-md-lu":"lu", "x-apple-i-md-rinfo":"r", "x-mme-device-id":"dev", "x-apple-i-srl-no":"sn", "x-mme-client-info":"ci", "user-agent":"ua", "x-apple-i-client-time":"time", "x-apple-locale":"en", "x-apple-i-timezone":"UTC"]
        let mapped = try EiliAnisetteService.convertHeaders(validHeaders)
        check(mapped.machineID == "m" && mapped.oneTimePassword == "otp" && mapped.deviceID == "dev" && mapped.timeZone == "UTC", "case insensitive header mapping")
        for key in validHeaders.keys { var missing = validHeaders; missing.removeValue(forKey: key); do { _ = try EiliAnisetteService.convertHeaders(missing); fatalError("missing header accepted: \(key)") } catch EiliAnisetteError.invalidHeaders {} }
        var empty = validHeaders; empty["user-agent"] = " \n"; do { _ = try EiliAnisetteService.convertHeaders(empty); fatalError("empty header accepted") } catch EiliAnisetteError.invalidHeaders {}

        func elf(machine: UInt8 = 183, bits: UInt8 = 2, kind: UInt8 = 3) -> Data {
            var b = [UInt8](repeating: 0, count: 65); b[0...3] = [0x7f, 0x45, 0x4c, 0x46]; b[4] = bits; b[5] = 1; b[6] = 1; b[16] = kind; b[18] = machine; return Data(b)
        }
        check(EiliAnisetteService.validLibrary(elf()), "valid ELF ARM64 rejected")
        check(!EiliAnisetteService.validLibrary(elf(machine: 62)), "x86-64 accepted")
        check(!EiliAnisetteService.validLibrary(elf(bits: 1)), "32-bit accepted")
        check(!EiliAnisetteService.validLibrary(elf(kind:  sharedObjectType)), "non-shared ELF accepted")
        check(!EiliAnisetteService.validLibrary(Data(elf().prefix(63))), "truncated ELF accepted")

        await manager.reset()
        let preCancelledService = EiliAnisetteService()
        let preCancelled = Task { try await preCancelledService.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .remote) }
        preCancelled.cancel()
        do { _ = try await preCancelled.value; fatalError("expected pre-cancellation") } catch is CancellationError {}
        let preCancelledCalls = await manager.calls; check(preCancelledCalls == 0, "pre-cancelled fetch called remote")

        await manager.reset(); await manager.setDelayForTests(800_000_000)
        let cancelled = Task { try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .remote) }
        try await Task.sleep(nanoseconds: 80_000_000); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("expected cancellation") } catch is CancellationError {}
        let cancelledCalls = await manager.calls; check(cancelledCalls == 1, "cancelled in-flight request should have only one call")
        await manager.reset()
        let serialized = EiliAnisetteService(); await manager.setDelayForTests(150_000_000)
        async let a = serialized.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .remote)
        async let b = serialized.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .remote)
        _ = try await (a, b)
        let maxConcurrent = await manager.maxConcurrentForTests; check(maxConcurrent == 1, "service gate allowed concurrent provider calls")

        // Active local session blocks destructive library operations before any filesystem interaction.
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.sessionKey)
        KeychainHelper.save(Data([1]), forKey: "paxstore.auth.session")
        do { try await serialized.resetLocal(); fatalError("expected logoutRequired") } catch EiliAnisetteError.logoutRequired {}
        #if EILI_ON_DEVICE_ANISETTE
        do {
            _ = try await serialized.downloadLibraries(using: { _ in fatalError("active local session reached network") })
            fatalError("active local session allowed download")
        } catch EiliAnisetteError.logoutRequired {}
        #endif
        KeychainHelper.delete(forKey: "paxstore.auth.session"); UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)
        #if EILI_ON_DEVICE_ANISETTE
        print("PASS: implicit cold-boot remote, unknown-preference remote, saved on-device local, preference switch to remote, build availability/mode cases, plus local/remote isolation and existing service checks")
        #else
        print("PASS: implicit cold-boot remote, unknown-preference remote, build availability/mode cases, plus remote routing/blob, local unavailable, header/ELF validation, cancellation, serialization and session guard checks")
        #endif
    }
}
private let sharedObjectType: UInt8 = 1
