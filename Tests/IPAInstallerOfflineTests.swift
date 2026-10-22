import Foundation
import SideSign

@main struct IPAInstallerOfflineTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("IPAInstallerOffline-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("original.ipa")
        let originalData = Data([1,2,3])
        try originalData.write(to: original)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let saved = docs.appendingPathComponent(ProcessInfo.processInfo.environment["IPA_TEST_BUNDLE_ID"]! + "-signed.ipa")
        defer { try? fm.removeItem(at: saved) }
        let installer = SourceAppInstaller.shared, signing = PaxSigningService.shared
        let device = AppInstaller.shared, manager = AppManager.shared
        func check(_ value: Bool, _ message: String) { precondition(value, "FAIL: \(message)") }
        func reset() {
            signing.events = []; signing.failAt = nil
            device.count = 0; device.shouldFail = false
            IPAParser.shouldFail = false; IPAParser.requireMetadataCalls = 0
            SignerTestState.count = 0; SignerTestState.shouldFail = false
        }
        reset()
        await installer.installImportedIPA(at: original)
        check(IPAParser.requireMetadataCalls == 1, "strict validation before signing")
        check(signing.events == ["fetchTeams","loadActiveCert","findOrCreateAppID","profile"], "shared signing sequence")
        check(SignerTestState.count == 1 && device.count == 1 && manager.count == 1, "sign, install then register")
        check(installer.statusMessage == "Fixture App 安裝完成" && installer.progress == 1 && !installer.isWorking, "success state")
        check(fm.fileExists(atPath: saved.path), "signed copy retained for future refresh")
        check(try Data(contentsOf: original) == originalData, "source unchanged")
        let stagedRoot = fm.temporaryDirectory.appendingPathComponent("EiliImportedIPAs")
        func checkStaging() { check((try? fm.contentsOfDirectory(atPath: stagedRoot.path).isEmpty) != false, "stage cleaned") }
        checkStaging()

        reset(); IPAParser.shouldFail = true
        await installer.installImportedIPA(at: original)
        check(signing.events.isEmpty && device.count == 0, "parse failure never signs or installs")
        check(!installer.isWorking && installer.progress == 0, "parse failure state")
        checkStaging()

        reset(); signing.failAt = "profile"
        await installer.installImportedIPA(at: original)
        check(SignerTestState.count == 0 && device.count == 0 && manager.count == 1, "profile failure no signing/install/register")
        check(!installer.isWorking && installer.progress == 0, "profile failure state")
        checkStaging()

        reset(); SignerTestState.shouldFail = true
        await installer.installImportedIPA(at: original)
        check(SignerTestState.count == 1 && device.count == 0 && manager.count == 1, "signer failure no install/register")
        checkStaging()

        reset(); device.shouldFail = true
        await installer.installImportedIPA(at: original)
        check(device.count == 1 && manager.count == 1, "install failure no registration")
        check(!installer.isWorking && installer.progress == 0, "install failure state")
        checkStaging()

        reset()
        let invalid = root.appendingPathComponent("bad.txt")
        try Data([4]).write(to: invalid)
        await installer.installImportedIPA(at: invalid)
        check(signing.events.isEmpty && device.count == 0, "invalid extension no signing")
        check(!installer.isWorking && installer.progress == 0, "invalid input state")

        reset(); signing.pause = DispatchSemaphore(value: 0)
        let first = Task { await installer.installImportedIPA(at: original) }
        for _ in 0..<500 {
            if signing.events.contains("fetchTeams") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(signing.events.contains("fetchTeams") && installer.isWorking, "first request reached signing")
        let before = signing.events.count
        await installer.installImportedIPA(at: original)
        check(signing.events.count == before, "concurrent request ignored")
        await first.value
        signing.pause = nil
        check(!installer.isWorking && manager.count == 2, "busy guard releases and first request completes")
        check(try Data(contentsOf: original) == originalData, "original unchanged after all scenarios")
        checkStaging()
        print("IPAInstallerOfflineTests: PASS (real installer, all external services mocked)")
    }
}
