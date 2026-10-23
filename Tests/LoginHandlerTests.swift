import Foundation
import SideSign

/// The runner extracts the production doLogin/finishLogin/cancelLogin methods verbatim.
/// Only UI storage and the SDK/network dependencies are replaced with offline fakes.
@main struct LoginHandlerTests {
    @MainActor static func main() async throws {
        EiliLoginDiagnostics.shared.clear()
        EiliAnisetteService.shared.failure = true
        let view = LoginHandlerHarness()
        view.appleID = "synthetic@example.invalid"
        view.password = "synthetic-password"
        view.doLogin()
        precondition(view.isLoading)
        let task = view.loginTask
        let provider = view.codeProvider
        view.doLogin() // double tap must not replace the active provider/task
        precondition(view.codeProvider === provider)
        let synchronousReport = EiliLoginDiagnostics.shared.report()
        for stage in ["loginTapped", "providerCreating", "providerReady", "loadingStateSet", "loginCallbacksReady", "loginTaskCreating", "loginTaskCreated"] {
            precondition(synchronousReport.contains(stage), "missing synchronous stage: \(stage)")
        }
        precondition(!synchronousReport.contains("loginTaskEntered"))
        await task?.value
        precondition(!view.isLoading && view.password.isEmpty && view.loginTask == nil)
        let report = EiliLoginDiagnostics.shared.report()
        precondition(report.contains("最近一次：failed"))
        let expected = ["loginTapped", "providerCreating", "providerReady", "loadingStateSet", "loginCallbacksReady", "loginTaskCreating", "loginTaskCreated", "loginTaskEntered", "authServiceCalling", "authServiceEntered", "loginStarted", "configurationLoading", "configurationReady"]
        var remainder = report[...]
        for stage in expected {
            guard let range = remainder.range(of: " \(stage)\n") ?? remainder.range(of: " \(stage)", options: .backwards) else {
                preconditionFailure("missing/out-of-order stage: \(stage)")
            }
            remainder = remainder[range.upperBound...]
        }
        precondition(!report.contains("synthetic"))
        precondition(SideSign.DeveloperPortal.authCalls == 0) // fake Anisette fails before auth

        // Cancel before the MainActor Task can start: no auth/service access and no false unfinished.
        view.password = "synthetic-password"
        view.doLogin()
        let cancelledTask = view.loginTask
        let fetches = EiliAnisetteService.shared.calls
        view.cancelLogin()
        await cancelledTask?.value
        let cancelled = EiliLoginDiagnostics.shared.report().components(separatedBy: "前一次")[0]
        precondition(cancelled.contains("最近一次：cancelled"))
        precondition(!cancelled.contains("authServiceCalling"))
        precondition(EiliAnisetteService.shared.calls == fetches && view.password.isEmpty)
        print("LoginHandlerTests: PASS (production handler, ordered early stages, task entry, double tap, immediate cancel; offline fake SDK only)")
    }
}
