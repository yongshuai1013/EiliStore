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

        // Structured Tasks retain TaskLocal context; detached tasks do not belong to a login.
        await EiliLoginDiagnostics.$attempt.withValue(next) {
            let inherited = await Task { EiliLoginDiagnostics.attempt }.value
            precondition(inherited == next)
            let detached = await Task.detached { EiliLoginDiagnostics.attempt }.value
            precondition(detached == nil)
        }
        print("EiliLoginDiagnosticsTests: PASS (abrupt exit/reopen, bounded storage, stale writes, outcomes, I/O failure, corrupt data, TaskLocal)")
    }
}
