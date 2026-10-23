import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct EiliLoginDiagnosticsTests {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let file = URL(fileURLWithPath: arguments[2])
        let store = EiliLoginDiagnostics(file: file)
        if arguments[1] == "interrupt-button" {
            store.begin(onDevice: true)
            _exit(86)
        }
        if arguments[1] == "verify-button" {
            let report = store.report()
            precondition(report.contains("最近一次：unfinished") && report.contains("loginTapped"))
            precondition(!report.contains("loginStarted"))
            print("EiliLoginDiagnosticsTests: PASS (button-only abrupt exit survives restart)")
            return
        }
        if arguments[1] == "interrupt" {
            let id = store.begin(onDevice: true)
            store.record(.nativeProvisionStartStarted, for: id)
            // Simulate abrupt process exit: no finish, defer, or crash handler runs.
            _exit(86)
        }
        let recovered = store.report()
        precondition(recovered.contains("unfinished") && recovered.contains("nativeProvisionStartStarted"))
        precondition(recovered.contains("onDevice"))
        let id = store.begin(onDevice: false)
        store.record(.authenticationStarted, for: UUID()) // stale/foreign updates ignored
        precondition(!store.report().contains("authenticationStarted"))
        for _ in 0..<100 { store.record(.configurationReady, for: id) }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let current = json["current"] as! [String: Any]
        precondition((current["entries"] as! [Any]).count == 48)
        let persistedSize = try Data(contentsOf: file).count
        precondition(persistedSize < 65536)
        store.finish(.succeeded, for: id)
        store.record(.sessionSaving, for: id) // completed attempt cannot be overwritten
        precondition(!store.report().contains("sessionSaving"))
        let reloaded = EiliLoginDiagnostics(file: file).report()
        precondition(reloaded.contains("succeeded") && reloaded.contains("nativeProvisionStartStarted"))
        let next = store.begin(onDevice: true)
        store.finish(.failed, for: next)
        precondition(!store.report().contains("nativeProvisionStartStarted")) // only two attempts
        store.clear()
        precondition(EiliLoginDiagnostics(file: file).report().contains("尚無登入階段紀錄"))

        let blocked = file.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        let failing = EiliLoginDiagnostics(file: blocked.appendingPathComponent("journal.json"))
        let failedID = failing.begin(onDevice: true)
        failing.record(.loginStarted, for: failedID)
        failing.finish(.failed, for: failedID)
        precondition(failing.report().contains("診斷寫入失敗"))
        precondition(failing.report().contains("loginStarted"))

        try Data("invalid-json".utf8).write(to: file)
        precondition(EiliLoginDiagnostics(file: file).report().contains("尚無登入階段紀錄"))
        try Data(repeating: 0, count: 65537).write(to: file)
        precondition(EiliLoginDiagnostics(file: file).report().contains("尚無登入階段紀錄"))

        // Explicit IDs work across detached Tasks, without task-local runtime state.
        let first = store.begin(onDevice: true)
        let relay = EiliLoginDiagnostics.Relay(store: store)
        relay.bind(first)
        await Task.detached { relay.record(.nativeHeadersStarted) }.value
        precondition(store.report().contains("nativeHeadersStarted"))
        store.finish(.failed, for: first)
        let second = store.begin(onDevice: true)
        relay.bind(second)
        relay.record(.nativeProvisionStartStarted)
        let latest = store.report().components(separatedBy: "前一次")[0]
        precondition(latest.contains("nativeProvisionStartStarted") && !latest.contains("nativeHeadersStarted"))
        relay.bind(nil)
        relay.record(.nativeProvisionEndStarted)
        precondition(!store.report().contains("nativeProvisionEndStarted"))
        let native = EiliLoginDiagnostics.NativeDetail(operation: .provisionStart,
            result: .providerError, phase: .loadLibrary, code: -2, nativeCode: -42)
        relay.record(native: native)
        precondition(!store.report().contains("nativeResponseFailed"))
        relay.bind(first) // completed/stale attempt must not receive numeric diagnostics
        relay.record(native: native)
        precondition(!store.report().contains("nativeResponseFailed"))
        relay.bind(second)
        relay.record(native: .init(operation: .provisionStart, result: .boundaryReturned,
            phase: nil, code: -2, nativeCode: nil))
        relay.record(native: native)
        let fault = EiliLoginDiagnostics.NativeDetail.Fault(unicornCode: 8, guestPC: UInt64.max,
            constructorKind: .initArray, constructorIndex: 3, constructorLibrary: .coreadi, reason: .engine,
            fetchAddress: 0xfedcba9876543210, pcTrail: [0x100, 0x200])
        relay.record(native: .init(operation: .provisionStart, result: .providerError,
            phase: .libraryConstructors, code: -2, nativeCode: nil, fault: fault))
        relay.record(native: .init(operation: .provisionStart, result: .providerError,
            phase: .libraryConstructors, code: -2, nativeCode: nil,
            fault: .init(unicornCode: 0, guestPC: 0x51000000, constructorKind: .dtInit,
                constructorIndex: 0, constructorLibrary: .storeservicescore, reason: .libc)))
        store.finish(.failed, for: second)
        let nativeReport = EiliLoginDiagnostics(file: file).report()
        precondition(nativeReport.contains("診斷 v4"))
        precondition(nativeReport.contains("nativeBoundaryReturned op=provisionStart result=boundaryReturned bridge=-2"))
        precondition(nativeReport.contains("nativeResponseFailed op=provisionStart result=providerError bridge=-2 phase=loadLibrary native=-42 (0xffffffd6)"))
        precondition(nativeReport.contains("fault=engine unicorn=8 guestPC=0xffffffffffffffff"))
        precondition(nativeReport.contains("ctorLibrary=coreadi ctorKind=initArray ctorIndex=3"))
        precondition(nativeReport.contains("fetchAddress=0xfedcba9876543210 pcTrail=[0x100,0x200]"))
        let isolatedFile = file.deletingLastPathComponent().appendingPathComponent("sanitized.json")
        let isolated = EiliLoginDiagnostics(file: isolatedFile)
        let isolatedID = isolated.begin(onDevice: true)
        let unrelated = EiliLoginDiagnostics.NativeDetail.Fault(unicornCode: 8, guestPC: 1, constructorKind: .initArray, constructorIndex: 0, constructorLibrary: .coreadi, reason: .engine, fetchAddress: 999, pcTrail: Array(0..<20).map(UInt64.init))
        isolated.record(native: .init(operation: .headers, result: .providerError, phase: .loadLibrary, code: -2, nativeCode: nil, fault: unrelated), for: isolatedID)
        let safeReport = isolated.report()
        precondition(!safeReport.contains("fetchAddress=0x3e7"), "unrelated phase fetch metadata must be omitted")
        let afterUnsafe = try JSONSerialization.jsonObject(with: Data(contentsOf: isolatedFile)) as! [String: Any]
        let currentAfterUnsafe = afterUnsafe["current"] as! [String: Any]
        let unsafeEntry = (currentAfterUnsafe["entries"] as! [[String: Any]]).first {
            let native = $0["native"] as? [String: Any]
            return native?["phase"] as? String == "loadLibrary" && native?["fault"] != nil
        }!
        let unsafeFault = ((unsafeEntry["native"] as! [String: Any])["fault"] as! [String: Any])
        precondition(unsafeFault["fetchAddress"] == nil && unsafeFault["pcTrail"] == nil, "unrelated phase fetch metadata not persisted")
        let longFault = EiliLoginDiagnostics.NativeDetail.Fault(unicornCode: 8, guestPC: 1, constructorKind: .initArray, constructorIndex: 0, constructorLibrary: .coreadi, reason: .engine, fetchAddress: 999, pcTrail: Array(0..<20).map(UInt64.init))
        isolated.record(native: .init(operation: .headers, result: .providerError, phase: .libraryConstructors, code: -2, nativeCode: nil, fault: longFault), for: isolatedID)
        let afterLong = try JSONSerialization.jsonObject(with: Data(contentsOf: isolatedFile)) as! [String: Any]
        let longEntries = ((afterLong["current"] as! [String: Any])["entries"] as! [[String: Any]])
        let longEntry = longEntries.first { ((($0["native"] as? [String: Any])?["fault"] as? [String: Any])?["fetchAddress"] as? NSNumber)?.uint64Value == 999 }!
        let longTrail = (((longEntry["native"] as! [String: Any])["fault"] as! [String: Any])["pcTrail"] as! [NSNumber]).map(\.uint64Value)
        precondition(longTrail == Array(UInt64(4)...UInt64(19)), "persist only newest sixteen PCs")
        let bounded = EiliLoginDiagnostics.NativeDetail.Fault(unicornCode: 8, guestPC: 1, constructorKind: .initArray, constructorIndex: 0, constructorLibrary: .coreadi, reason: .engine, fetchAddress: 999, pcTrail: Array(0..<20).map(UInt64.init)).sanitizedFetchFields(phase: .libraryConstructors)
        precondition(bounded.pcTrail == Array(UInt64(4)...UInt64(19)), "persisted report trail bounded to newest 16")
        precondition(nativeReport.contains("fault=libc unicorn=0 guestPC=0x51000000 ctorLibrary=storeservicescore ctorKind=dtInit ctorIndex=0"))
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let savedCurrent = persisted["current"] as! [String: Any]
        let savedEntries = savedCurrent["entries"] as! [[String: Any]]
        let savedFaultEntry = savedEntries.first { ($0["native"] as? [String: Any])?["fault"] != nil }!
        let savedFault = (savedFaultEntry["native"] as! [String: Any])["fault"] as! [String: Any]
        precondition((savedFault["fetchAddress"] as? NSNumber)?.uint64Value == 0xfedcba9876543210)
        precondition((savedFault["pcTrail"] as? [NSNumber])?.map(\.uint64Value) == [0x100, 0x200])
        relay.record(native: .init(operation: .headers, result: .invalidJSON, phase: nil, code: -5, nativeCode: nil))
        precondition(!store.report().contains("result=invalidJSON"))
        var v3Journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for key in ["current", "previous"] {
            if var attempt = v3Journal[key] as? [String: Any], let entries = attempt["entries"] as? [[String: Any]] {
                attempt["entries"] = entries.map { entry in
                    var entry = entry
                    if var native = entry["native"] as? [String: Any] {
                        native.removeValue(forKey: "fault")
                        entry["native"] = native
                    }
                    return entry
                }
                v3Journal[key] = attempt
            }
        }
        try JSONSerialization.data(withJSONObject: v3Journal).write(to: file)
        let v3Report = EiliLoginDiagnostics(file: file).report()
        precondition(v3Report.contains("native=-42") && v3Report.contains("最近一次：failed"))
        precondition(!v3Report.contains("guestPC=0x"))
        // An actual v2 shape has no optional native key, and must remain readable.
        var v2Journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        for key in ["current", "previous"] {
            if var attempt = v2Journal[key] as? [String: Any], let entries = attempt["entries"] as? [[String: Any]] {
                attempt["entries"] = entries.filter { $0["native"] == nil }
                v2Journal[key] = attempt
            }
        }
        try JSONSerialization.data(withJSONObject: v2Journal).write(to: file)
        let v2Report = EiliLoginDiagnostics(file: file).report()
        precondition(v2Report.contains("nativeProvisionStartStarted") && v2Report.contains("最近一次：failed"))
        EiliLoginDiagnostics.record(.authenticationStarted, for: nil)
        print("EiliLoginDiagnosticsTests: PASS (abrupt exit/reopen, bounded storage, stale writes, outcomes, I/O failure, corrupt data, explicit ID/relay/detached Task)")
    }
}
