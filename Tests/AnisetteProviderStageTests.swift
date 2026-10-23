import Foundation
import anisette_core

@_silgen_name("anisette_stage_test_set_mode")
private func setMode(_ mode: Int32)

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private final class DiagnosticBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AnisetteProviderDiagnostic] = []
    func append(_ value: AnisetteProviderDiagnostic) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    func snapshot() -> [AnisetteProviderDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AnisetteProviderStage] = []
    func append(_ stage: AnisetteProviderStage) {
        lock.lock()
        values.append(stage)
        lock.unlock()
    }
    func snapshot() -> [AnisetteProviderStage] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func capture(_ operation: (@escaping @Sendable (AnisetteProviderStage) -> Void) -> Void)
    -> [AnisetteProviderStage]
{
    let box = StageBox()
    operation { box.append($0) }
    return box.snapshot()
}

@main
struct AnisetteProviderStageTests {
    static func main() async throws {
        let lib = "/synthetic"
        let provisioning = "/synthetic"
        let headers = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.getAnisetteHeaders(
                libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
            check(
                result.oneTimePassword == "synthetic-otp" && result.machineID == "synthetic-machine",
                "synthetic headers")
        }
        check(headers == [AnisetteProviderStage.headersStarted, .headersReturned], "headers stage order")
        let started = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.startProvision(
                libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
            check(result.cpim == Data([1, 2, 3]) && result.session == 1234, "synthetic start result")
        }
        check(started == [AnisetteProviderStage.provisionStartStarted, .provisionStartReturned], "start stage order")
        let ended = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.endProvision(
                libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1234, ptm: [2], tk: [3])
            check(result == Data([4, 5, 6]), "synthetic end result")
        }
        check(ended == [AnisetteProviderStage.provisionEndStarted, .provisionEndReturned], "end stage order")

        for (mode, invoke, onlyStarted) in [
            (Int32(1), 0, AnisetteProviderStage.headersStarted),
            (Int32(1), 1, AnisetteProviderStage.provisionStartStarted),
            (Int32(1), 2, AnisetteProviderStage.provisionEndStarted),
            (Int32(2), 0, AnisetteProviderStage.headersStarted),
            (Int32(2), 1, AnisetteProviderStage.provisionStartStarted),
            (Int32(2), 2, AnisetteProviderStage.provisionEndStarted),
        ] {
            setMode(mode)
            let stages = capture { callback in
                let p = UnicornAnisetteDataProvider(onStage: callback)
                do {
                    switch invoke {
                    case 0:
                        _ = try p.getAnisetteHeaders(
                            libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
                    case 1:
                        _ = try p.startProvision(libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
                    default:
                        _ = try p.endProvision(
                            libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1, ptm: [2], tk: [3])
                    }
                    fatalError("expected C/JSON failure")
                } catch {}
            }
            check(stages == [onlyStarted], "failure must report Started only: \(stages)")
        }
        setMode(0)

        func diagnose(_ mode: Int32, operation: AnisetteProviderDiagnostic.Operation = .headers)
            -> [AnisetteProviderDiagnostic]
        {
            setMode(mode)
            let box = DiagnosticBox()
            let p = UnicornAnisetteDataProvider(onDiagnostic: { box.append($0) })
            do {
                switch operation {
                case .headers:
                    _ = try p.getAnisetteHeaders(
                        libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
                case .provisionStart:
                    _ = try p.startProvision(libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
                case .provisionEnd:
                    _ = try p.endProvision(
                        libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1, ptm: [2], tk: [3])
                }
            } catch {}
            return box.snapshot()
        }
        let nilEvents = diagnose(1)
        check(
            nilEvents.map(\.result) == [.boundaryReturned, .nilResponse] && nilEvents[1].code == -2,
            "nil diagnostics preserve bridge code")
        let malformed = diagnose(2)
        check(
            malformed.map(\.result) == [.boundaryReturned, .invalidJSON] && malformed[1].code == -5,
            "malformed diagnostics")
        let adi = diagnose(3)
        check(
            adi.map(\.result) == [.boundaryReturned, .providerError] && adi[1].code == -12345, "ADI code diagnostics")
        let loader = diagnose(4)
        check(
            loader[1].nativeCode == -42 && loader[1].phase == .loadLibrary && loader[1].code == -2,
            "loader metadata allowlist")
        let nonzeroSuccess = diagnose(5)
        check(nonzeroSuccess.map(\.result) == [.boundaryReturned, .providerError], "nonzero code cannot succeed")
        let zeroError = diagnose(6)
        check(zeroError.map(\.result) == [.boundaryReturned, .providerError], "zero code error JSON")
        let unsafe = diagnose(7)
        check(
            unsafe[1].nativeCode == nil && unsafe[1].phase == nil && !String(describing: unsafe).contains("SECRET")
                && !String(describing: unsafe).contains("private"), "diagnostics exclude payload/path")
        let fractional = diagnose(8)
        check(fractional[1].nativeCode == nil && fractional[1].phase == .loadLibrary, "invalid native number ignored")
        let missing = diagnose(9)
        check(missing.map(\.result) == [.boundaryReturned, .invalidResponse], "missing fields diagnosed")
        for operation in [AnisetteProviderDiagnostic.Operation.provisionStart, .provisionEnd] {
            for mode in Int32(1)...9 {
                let expected = diagnose(mode)
                let actual = diagnose(mode, operation: operation)
                check(
                    actual.count == 2 && actual.allSatisfy { $0.operation == operation },
                    "operation metadata or event count incorrect")
                check(actual.map(\.result) == expected.map(\.result), "operation error classification mismatch")
                check(actual.map(\.code) == expected.map(\.code), "operation bridge code mismatch")
                check(actual.map(\.nativeCode) == expected.map(\.nativeCode), "operation native code lost")
                check(actual.map(\.phase) == expected.map(\.phase), "operation native phase lost")
            }
        }
        setMode(0)
        let successBox = DiagnosticBox()
        let successProvider = UnicornAnisetteDataProvider(onDiagnostic: { successBox.append($0) })
        _ = try successProvider.getAnisetteHeaders(
            libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
        check(successBox.snapshot().map(\.result) == [.boundaryReturned, .parsed], "success diagnostics")
        setMode(0)

        // The protocol declares async requirements; verify dispatch via that surface too.
        let asyncBox = StageBox()
        let provider: any AnisetteDataProvider = UnicornAnisetteDataProvider(onStage: { asyncBox.append($0) })
        _ = try await provider.getAnisetteHeaders(
            libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
        let asyncStages = asyncBox.snapshot()
        check(
            asyncStages == [AnisetteProviderStage.headersStarted, .headersReturned], "async protocol dispatch stages")
        let asyncDiagnostics = DiagnosticBox()
        let asyncDiagnosticProvider: any AnisetteDataProvider = UnicornAnisetteDataProvider(onDiagnostic: {
            asyncDiagnostics.append($0)
        })
        _ = try await asyncDiagnosticProvider.getAnisetteHeaders(
            libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
        check(asyncDiagnostics.snapshot().map(\.result) == [.boundaryReturned, .parsed], "async diagnostic dispatch")
        print("Anisette provider stage synthetic tests passed")
    }
}
