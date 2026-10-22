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
        await manager.reset()
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.preferenceKey)
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)
        check(EiliAnisetteMode.selected == .remote, "preference default must be remote")
        UserDefaults.standard.set("nonsense", forKey: EiliAnisetteMode.preferenceKey)
        check(EiliAnisetteMode.selected == .remote, "unknown preference must default remote")
        UserDefaults.standard.set("nonsense", forKey: EiliAnisetteMode.sessionKey)
        check(EiliAnisetteMode.savedSessionMode == .remote, "unknown session mode must default remote")
        UserDefaults.standard.set("onDevice", forKey: EiliAnisetteMode.sessionKey)
        check(EiliAnisetteMode.savedSessionMode == .onDevice, "session mode mapping")
        UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)

        let svc = EiliAnisetteService(), id = UUID(), blob = Data([1, 2]), responseBlob = Data([9, 8])
        let urls = [URL(string: "https://first.invalid")!, URL(string: "https://second.invalid")!]
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
            do { _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice); fatalError("expected localBuildRequired") }
            catch EiliAnisetteError.localBuildRequired {}
            let localCalls = await manager.calls; check(localCalls == 0, "unavailable local mode called remote")
        }

        #if EILI_ON_DEVICE_ANISETTE
        let fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent("anisette-elf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        let elfFiles = try ELFLibraryFixtures.write(to: fixtureDir)
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EiliStore/OnDeviceAnisette", isDirectory: true)
        try? FileManager.default.removeItem(at: supportRoot)
        FakeAnisetteKitControl.reset()
        let remoteCallsBeforeMissing = await manager.calls
        do { _ = try await svc.fetch(remoteIdentifier: id, remoteBlob: nil, servers: urls, mode: .onDevice); fatalError("expected missing local libraries") }
        catch EiliAnisetteError.missingLibraries {}
        check(FakeAnisetteKitControl.calls == 0, "missing libraries reached local provider")
        let remoteCallsAfterMissing = await manager.calls
        check(remoteCallsBeforeMissing == remoteCallsAfterMissing, "missing local libraries fell back to remote")
        try await svc.importLibraries(elfFiles)
        let localResponseBlob = Data([0x10, 0x20, 0x30])
        FakeAnisetteKitControl.reset()
        FakeAnisetteKitControl.configure(blob: localResponseBlob)
        let remoteBlobBeforeLocal = Data([0xBA, 0xAD])
        KeychainHelper.save(remoteBlobBeforeLocal, forKey: "paxstore.anisette.adiblob")
        let localData = try await svc.fetch(remoteIdentifier: id, remoteBlob: blob, servers: urls, mode: .onDevice)
        check(FakeAnisetteKitControl.calls == 1 && FakeAnisetteKitControl.identifier != nil, "local provider not called")
        check(localData.machineID == "v0" && localData.oneTimePassword == "v1", "local header conversion")
        check(KeychainHelper.load(forKey: "eilistore.anisette.local.adiblob") == localResponseBlob, "local blob persistence")
        check(KeychainHelper.load(forKey: "paxstore.anisette.adiblob") == remoteBlobBeforeLocal, "local branch modified remote blob")
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
        KeychainHelper.delete(forKey: "paxstore.auth.session"); UserDefaults.standard.removeObject(forKey: EiliAnisetteMode.sessionKey)
        #if EILI_ON_DEVICE_ANISETTE
        print("PASS: 19 coverage groups (14 shared/remote groups plus local missing-library isolation, ELF import and local identity/blob isolation, persist-before-cancellation, no remote fallback, reset isolation)")
        #else
        print("PASS: 14 coverage groups (mode mapping, remote defaults/routing/blob, local unavailable, 11 required headers, ELF variants, cancellation, serialization gate, active-session reset guard)")
        #endif
    }
}
private let sharedObjectType: UInt8 = 1
