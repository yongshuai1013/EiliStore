import Foundation
import anisette_core

@_silgen_name("anisette_stage_test_set_mode")
private func setMode(_ mode: Int32)

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AnisetteProviderStage] = []
    func append(_ stage: AnisetteProviderStage) { lock.lock(); values.append(stage); lock.unlock() }
    func snapshot() -> [AnisetteProviderStage] { lock.lock(); defer { lock.unlock() }; return values }
}

private func capture(_ operation: (@escaping @Sendable (AnisetteProviderStage) -> Void) -> Void) -> [AnisetteProviderStage] {
    let box = StageBox()
    operation { box.append($0) }
    return box.snapshot()
}

@main
struct AnisetteProviderStageTests {
    static func main() async throws {
        let lib = "/synthetic", provisioning = "/synthetic"
        let headers = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.getAnisetteHeaders(libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
            check(result.oneTimePassword == "synthetic-otp" && result.machineID == "synthetic-machine", "synthetic headers")
        }
        check(headers == [AnisetteProviderStage.headersStarted, .headersReturned], "headers stage order")
        let started = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.startProvision(libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
            check(result.cpim == Data([1,2,3]) && result.session == 1234, "synthetic start result")
        }
        check(started == [AnisetteProviderStage.provisionStartStarted, .provisionStartReturned], "start stage order")
        let ended = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.endProvision(libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1234, ptm: [2], tk: [3])
            check(result == Data([4,5,6]), "synthetic end result")
        }
        check(ended == [AnisetteProviderStage.provisionEndStarted, .provisionEndReturned], "end stage order")

        for (mode, invoke, onlyStarted) in [
            (Int32(1), 0, AnisetteProviderStage.headersStarted),
            (Int32(1), 1, AnisetteProviderStage.provisionStartStarted),
            (Int32(1), 2, AnisetteProviderStage.provisionEndStarted),
            (Int32(2), 0, AnisetteProviderStage.headersStarted),
            (Int32(2), 1, AnisetteProviderStage.provisionStartStarted),
            (Int32(2), 2, AnisetteProviderStage.provisionEndStarted)
        ] {
            setMode(mode)
            let stages = capture { callback in
                let p = UnicornAnisetteDataProvider(onStage: callback)
                do {
                    switch invoke {
                    case 0: _ = try p.getAnisetteHeaders(libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
                    case 1: _ = try p.startProvision(libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
                    default: _ = try p.endProvision(libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1, ptm: [2], tk: [3])
                    }
                    fatalError("expected C/JSON failure")
                } catch { }
            }
            check(stages == [onlyStarted], "failure must report Started only: \(stages)")
        }
        setMode(0)

        // The protocol declares async requirements; verify dispatch via that surface too.
        let asyncBox = StageBox()
        let provider: any AnisetteDataProvider = UnicornAnisetteDataProvider(onStage: { asyncBox.append($0) })
        _ = try await provider.getAnisetteHeaders(libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
        let asyncStages = asyncBox.snapshot()
        check(asyncStages == [AnisetteProviderStage.headersStarted, .headersReturned], "async protocol dispatch stages")
        print("Anisette provider stage synthetic tests passed")
    }
}
