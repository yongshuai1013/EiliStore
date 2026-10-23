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
        check(
            headers == [AnisetteProviderStage.headersStarted, .headersReturned], "headers stage order")
        let started = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.startProvision(
                libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
            check(result.cpim == Data([1, 2, 3]) && result.session == 1234, "synthetic start result")
        }
        check(
            started == [AnisetteProviderStage.provisionStartStarted, .provisionStartReturned],
            "start stage order")
        let ended = capture { callback in
            let provider = UnicornAnisetteDataProvider(onStage: callback)
            let result = try! provider.endProvision(
                libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1234, ptm: [2],
                tk: [3])
            check(result == Data([4, 5, 6]), "synthetic end result")
        }
        check(
            ended == [AnisetteProviderStage.provisionEndStarted, .provisionEndReturned], "end stage order"
        )

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
                        _ = try p.startProvision(
                            libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
                    default:
                        _ = try p.endProvision(
                            libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1, ptm: [2],
                            tk: [3])
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
                    _ = try p.startProvision(
                        libDir: lib, provisioningDir: provisioning, identifier: [1], spim: [2])
                case .provisionEnd:
                    _ = try p.endProvision(
                        libDir: lib, provisioningDir: provisioning, identifier: [1], session: 1, ptm: [2],
                        tk: [3])
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
            adi.map(\.result) == [.boundaryReturned, .providerError] && adi[1].code == -12345,
            "ADI code diagnostics")
        let loader = diagnose(4)
        check(
            loader[1].nativeCode == -42 && loader[1].phase == .loadLibrary && loader[1].code == -2,
            "loader metadata allowlist")
        let nonzeroSuccess = diagnose(5)
        check(
            nonzeroSuccess.map(\.result) == [.boundaryReturned, .providerError],
            "nonzero code cannot succeed")
        let zeroError = diagnose(6)
        check(zeroError.map(\.result) == [.boundaryReturned, .providerError], "zero code error JSON")
        let unsafe = diagnose(7)
        check(
            unsafe[1].nativeCode == nil && unsafe[1].phase == nil
                && !String(describing: unsafe).contains("SECRET")
                && !String(describing: unsafe).contains("private"), "diagnostics exclude payload/path")
        let fractional = diagnose(8)
        check(
            fractional[1].nativeCode == nil && fractional[1].phase == .loadLibrary,
            "invalid native number ignored")
        let missing = diagnose(9)
        check(
            missing.map(\.result) == [.boundaryReturned, .invalidResponse], "missing fields diagnosed")
        for operation in [AnisetteProviderDiagnostic.Operation.provisionStart, .provisionEnd] {
            for mode in Int32(1)...9 {
                let expected = diagnose(mode)
                let actual = diagnose(mode, operation: operation)
                check(
                    actual.count == 2 && actual.allSatisfy { $0.operation == operation },
                    "operation metadata or event count incorrect")
                check(
                    actual.map(\.result) == expected.map(\.result), "operation error classification mismatch")
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
        check(
            successBox.snapshot().map(\.result) == [.boundaryReturned, .parsed], "success diagnostics")
        setMode(0)

        func parseFaultJSON(_ json: String) throws -> AnisetteProviderDiagnostic.Fault? {
            let pointer = strdup(json)
            defer { free(pointer) }
            let box = DiagnosticBox()
            do {
                _ = try UnicornAnisetteDataProvider().parseHeadersResponse(
                    code: -1, outPtr: pointer, providerName: "synthetic",
                    diagnostic: { result, _, _, fault in
                        box.append(.init(operation: .headers, result: result, code: -1, fault: fault))
                    })
            } catch {}
            return box.snapshot().last?.fault
        }
        let trailJSON = String((0..<20).map(String.init).joined(separator: ","))
        let validFault = try parseFaultJSON("{\"error\":\"safe\",\"unicorn_code\":8,\"constructor_kind\":\"initArray\",\"constructor_index\":2,\"constructor_library\":\"coreadi\",\"fault_reason\":\"engine\",\"diagnostic_phase\":\"libraryConstructors\",\"fetch_address\":18446744073709551615,\"pc_trail\":[\(trailJSON)]}")
        check(validFault?.fetchAddress == UInt64.max, "fetch address parsed unsigned")
        check(validFault?.pcTrail == Array(UInt64(4)...UInt64(19)), "trail capped to newest 16 entries")
        let malformedTrail = try parseFaultJSON("{\"error\":\"safe\",\"unicorn_code\":8,\"constructor_kind\":\"initArray\",\"constructor_index\":2,\"constructor_library\":\"coreadi\",\"fault_reason\":\"engine\",\"diagnostic_phase\":\"libraryConstructors\",\"pc_trail\":[1,true,3]}")
        check(malformedTrail?.pcTrail == nil, "invalid trail rejected as a whole")
        let unrelatedFault = try parseFaultJSON("{\"error\":\"safe\",\"unicorn_code\":0,\"constructor_kind\":\"dtInit\",\"constructor_index\":0,\"constructor_library\":\"coreadi\",\"fault_reason\":\"libc\",\"fetch_address\":123,\"pc_trail\":[1]}")
        check(unrelatedFault?.fetchAddress == nil && unrelatedFault?.pcTrail == nil, "unrelated fault fields ignored")
        let branchJSON = #"{"error":"safe","unicorn_code":8,"constructor_kind":"initArray","constructor_index":2,"constructor_library":"storeservicescore","fault_reason":"engine","diagnostic_phase":"libraryConstructors","cxa_atexit_branch":{"target":2,"got_address":3,"got_value":null,"registered_stub":true,"resolution_source":"functionStub"}}"#
        let validBranch = try parseFaultJSON(branchJSON)?.cxaAtexitBranch
        check(validBranch?.gotValue == nil && validBranch?.registeredStub == true && validBranch?.resolutionSource.rawValue == "functionStub", "strict branch object or optional got value")
        let malformedBranch = try parseFaultJSON(branchJSON.replacingOccurrences(of: "\"target\":2", with: "\"target\":true"))?.cxaAtexitBranch
        check(malformedBranch == nil, "boolean accepted as branch UInt64")
        let unknownBranch = try parseFaultJSON(branchJSON.replacingOccurrences(of: "\"got_address\":3", with: "\"got_address\":3,\"register_dump\":\"sensitive\""))?.cxaAtexitBranch
        check(unknownBranch == nil, "unknown branch field accepted")
        let branchFields: [(String, String)] = [
            ("target", "-1"), ("target", "1.5"), ("target", "\"1\""), ("target", "true"),
            ("target", "18446744073709551616"),
            ("got_address", "-1"), ("got_address", "1.5"), ("got_address", "\"1\""),
            ("got_address", "false"), ("got_address", "18446744073709551616"),
            ("got_value", "-1"), ("got_value", "1.5"), ("got_value", "\"1\""),
            ("got_value", "true"), ("got_value", "18446744073709551616"),
        ]
        for (key, invalidValue) in branchFields {
            let needle = "\"\(key)\":\(key == "got_value" ? "null" : key == "target" ? "2" : "3")"
            let invalid = branchJSON.replacingOccurrences(of: needle, with: "\"\(key)\":\(invalidValue)")
            let decodedInvalid = try parseFaultJSON(invalid)?.cxaAtexitBranch
            check(decodedInvalid == nil, "invalid UInt64 branch field accepted: \(key)=\(invalidValue)")
        }
        for invalidRegistered in ["0", "1", "\"true\""] {
            let invalid = branchJSON.replacingOccurrences(of: "\"registered_stub\":true", with: "\"registered_stub\":\(invalidRegistered)")
            let decodedInvalid = try parseFaultJSON(invalid)?.cxaAtexitBranch
            check(decodedInvalid == nil, "invalid registered_stub accepted: \(invalidRegistered)")
        }
        for invalidEnum in ["unknownSource", "FunctionStub"] {
            let invalid = branchJSON.replacingOccurrences(of: "functionStub", with: invalidEnum)
            let decodedInvalid = try parseFaultJSON(invalid)?.cxaAtexitBranch
            check(decodedInvalid == nil, "unknown branch enum accepted")
        }
        let maxBranchJSON = #"{"error":"safe","unicorn_code":8,"constructor_kind":"initArray","constructor_index":2,"constructor_library":"storeservicescore","fault_reason":"engine","diagnostic_phase":"libraryConstructors","cxa_atexit_branch":{"target":18446744073709551615,"got_address":18446744073709551615,"got_value":18446744073709551615,"registered_stub":true,"resolution_source":"unresolved"}}"#
        let maxBranch = try parseFaultJSON(maxBranchJSON)?.cxaAtexitBranch
        check(maxBranch?.target == UInt64.max && maxBranch?.gotAddress == UInt64.max && maxBranch?.gotValue == UInt64.max, "UInt64.max branch fields failed to parse")
        let disallowedBranchContexts = [
            branchJSON.replacingOccurrences(of: "\"fault_reason\":\"engine\"", with: "\"fault_reason\":\"libc\""),
            branchJSON.replacingOccurrences(of: "\"unicorn_code\":8", with: "\"unicorn_code\":7"),
            branchJSON.replacingOccurrences(of: "\"diagnostic_phase\":\"libraryConstructors\"", with: "\"diagnostic_phase\":\"loadLibrary\""),
            branchJSON.replacingOccurrences(of: "\"constructor_library\":\"storeservicescore\"", with: "\"constructor_library\":\"coreadi\"")
        ]
        for json in disallowedBranchContexts {
            let decodedInvalid = try parseFaultJSON(json)?.cxaAtexitBranch
            check(decodedInvalid == nil, "branch accepted outside allowlisted context")
        }

        let expectedFaults: [(Int32, AnisetteProviderDiagnostic.Fault)] = [
            (
                10,
                .init(
                    unicornCode: 8, guestPC: 1_234_605_616_436_508_552,
                    constructorKind: .dtInit, constructorIndex: 0,
                    constructorLibrary: .storeservicescore, reason: .constructorRead)
            ),
            (
                11,
                .init(
                    unicornCode: 8, guestPC: UInt64.max,
                    constructorKind: .initArray, constructorIndex: 3,
                    constructorLibrary: .coreadi, reason: .constructorRead)
            ),
            (
                12,
                .init(
                    unicornCode: 8, constructorKind: .initArray, constructorIndex: 4,
                    constructorLibrary: .coreadi, reason: .constructorRead)
            ),
            (15, .init(reason: .libc)),
            (20, .init(unicornCode: 0, reason: .libc)),
        ]
        for operation in AnisetteProviderDiagnostic.Operation.allCases {
            for (mode, expectedFault) in expectedFaults {
                let events = diagnose(mode, operation: operation)
                check(
                    events.count == 2 && events[0].fault == nil && events[1].fault == expectedFault,
                    "fault metadata lost for \(operation): \(events)")
            }
            for mode in [Int32(13), 14, 16, 17, 18, 19] {
                let events = diagnose(mode, operation: operation)
                check(events[1].fault == nil, "invalid fault values accepted: \(events[1].fault as Any)")
            }
        }
        setMode(0)

        // The protocol declares async requirements; verify dispatch via that surface too.
        let asyncBox = StageBox()
        let provider: any AnisetteDataProvider = UnicornAnisetteDataProvider(onStage: {
            asyncBox.append($0)
        })
        _ = try await provider.getAnisetteHeaders(
            libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
        let asyncStages = asyncBox.snapshot()
        check(
            asyncStages == [AnisetteProviderStage.headersStarted, .headersReturned],
            "async protocol dispatch stages")
        let asyncDiagnostics = DiagnosticBox()
        let asyncDiagnosticProvider: any AnisetteDataProvider = UnicornAnisetteDataProvider(
            onDiagnostic: {
                asyncDiagnostics.append($0)
            })
        _ = try await asyncDiagnosticProvider.getAnisetteHeaders(
            libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2])
        check(
            asyncDiagnostics.snapshot().map(\.result) == [.boundaryReturned, .parsed],
            "async diagnostic dispatch")
        setMode(10)
        let asyncFaultDiagnostics = DiagnosticBox()
        let asyncFaultProvider: any AnisetteDataProvider = UnicornAnisetteDataProvider(onDiagnostic: {
            asyncFaultDiagnostics.append($0)
        })
        do {
            _ = try await asyncFaultProvider.getAnisetteHeaders(
                libDir: lib, provisioningDir: provisioning, identifier: [1], adiPb: [2]
            )
        } catch {}
        check(
            asyncFaultDiagnostics.snapshot()[1].fault?.constructorKind == .dtInit,
            "async diagnostic fault dispatch")
        print("Anisette provider stage synthetic tests passed")
    }
}
