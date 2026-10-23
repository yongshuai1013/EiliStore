import SwiftUI
import UIKit

struct EiliLoginDiagnosticsView: View {
    @State private var report = ""
    @State private var copied = false
    let loginInProgress: Bool

    var body: some View {
        List {
            Section(footer: Text("App 結束後重開，仍可查看最後成功落盤的階段。未完成紀錄不代表已確認閃退或記憶體不足。只保留最近兩次登入，不會自動上傳。")) {
                Button(copied ? "已複製診斷" : "複製診斷") {
                    report = EiliLoginDiagnostics.shared.report()
                    UIPasteboard.general.string = report
                    copied = true
                }
                Button("重新讀取") {
                    report = EiliLoginDiagnostics.shared.report()
                    copied = false
                }
                Button("清除階段紀錄", role: .destructive) {
                    EiliLoginDiagnostics.shared.clear()
                    report = EiliLoginDiagnostics.shared.report()
                    copied = false
                }
                .disabled(loginInProgress)
            }
            Section(header: Text("本機登入階段（不含登入資料）")) {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("登入診斷")
        .onAppear { report = EiliLoginDiagnostics.shared.report() }
    }
}
