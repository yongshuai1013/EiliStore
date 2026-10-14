import Foundation
import SwiftUI

/// 全局日誌：App 內所有操作都寫到這裡
class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    @Published var logs: String = ""
    @Published var autoScroll: Bool = true
    
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    
    private init() {}
    
    /// 寫日誌
    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        DispatchQueue.main.async {
            self.logs += line
            // 限制長度，避免無限增長
            if self.logs.count > 50000 {
                self.logs = String(self.logs.suffix(40000))
            }
        }
        print("[EiliStore] \(message)")
    }
    
    func clear() {
        logs = ""
    }
    
    /// 導出日誌為文本
    func exportText() -> String {
        return logs
    }
}

/// 日誌視圖
struct LogView: View {
    @StateObject private var logger = AppLogger.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 工具欄
            HStack {
                Text("日誌")
                    .font(.headline)
                Spacer()
                Toggle("自動滾動", isOn: $logger.autoScroll)
                    .font(.caption)
                Button("清空") {
                    logger.clear()
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // 日誌內容
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logger.logs.isEmpty ? "暫無日誌" : logger.logs)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                    Color.clear
                        .frame(height: 1)
                        .id("logBottom")
                }
                .background(Color.black.opacity(0.05))
                .onChange(of: logger.logs) { _ in
                    if logger.autoScroll {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("日誌")
        .navigationBarTitleDisplayMode(.inline)
    }
}
