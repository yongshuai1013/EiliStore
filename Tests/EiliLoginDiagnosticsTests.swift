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
        store.finish(.failed, for: second)
        let nativeReport = EiliLoginDiagnostics(file: file).report()
        precondition(nativeReport.contains("診斷 v3"))
        precondition(nativeReport.contains("nativeBoundaryReturned op=provisionStart result=boundaryReturned bridge=-2"))
        precondition(nativeReport.contains("nativeResponseFailed op=provisionStart result=providerError bridge=-2 phase=loadLibrary native=-42 (0xffffffd6)"))
        relay.record(native: .init(operation: .headers, result: .invalidJSON, phase: nil, code: -5, nativeCode: nil))
        precondition(!store.report().contains("result=invalidJSON"))
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
