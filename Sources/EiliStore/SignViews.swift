import SwiftUI

/// Apple ID 登入頁
struct SignInView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isLoggedIn = false
    @StateObject private var logger = AppLogger.shared
    
    var body: some View {
        Form {
            Section(header: Text("Apple ID")) {
                TextField("Apple ID", text: $appleID)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .disabled(isLoading || isLoggedIn)
                if !isLoggedIn {
                    SecureField("密碼", text: $password)
                        .textContentType(.password)
                        .disabled(isLoading)
                }
            }
            
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            Section {
                if isLoggedIn {
                    HStack {
                        Spacer()
                        Text("已登入: \(appleID)")
                            .foregroundColor(.teal)
                        Spacer()
                    }
                    Button("登出", role: .destructive) {
                        // TODO: 清除 Keychain
                        isLoggedIn = false
                        appleID = ""
                        password = ""
                        logger.log("已登出")
                    }
                } else {
                    Button(action: doLogin) {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("登入")
                            }
                            Spacer()
                        }
                    }
                    .disabled(appleID.isEmpty || password.isEmpty || isLoading)
                }
            }
            
            Section(header: Text("說明")) {
                Text("登入後可用於簽名 IPA。帳號信息保存在 Keychain。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Apple ID 登入")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 檢查是否已登入
            if KeychainHelper.loadString(forKey: "paxstore.auth.session") != nil {
                // 簡化：只檢查有沒有存過，實際應該驗證 session 有效性
                isLoggedIn = true
                appleID = KeychainHelper.loadString(forKey: "paxstore.apple.id") ?? ""
            }
        }
    }
    
    private func doLogin() {
        isLoading = true
        errorMessage = nil
        logger.log("開始登入: \(appleID)")
        
        Task {
            do {
                // TODO: 實際調用 PaxAuthService 登入
                // 這裡先做個佔位，實際需要處理 2FA
                try await Task.sleep(nanoseconds: 2_000_000_000)
                
                // 臨時：保存到 Keychain（演示）
                KeychainHelper.saveString(appleID, forKey: "paxstore.apple.id")
                
                await MainActor.run {
                    isLoggedIn = true
                    isLoading = false
                    logger.log("✅ 登入成功: \(appleID)")
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    logger.log("❌ 登入失敗: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// 簽名 IPA 頁（UI 空殼，後端待接）
struct SignIPAView: View {
    @State private var selectedIPA: String? = nil
    @State private var isSigning = false
    @State private var progress = ""
    
    var body: some View {
        List {
            Section(header: Text("IPA 文件")) {
                Button("選擇 IPA") {}
                if let ipa = selectedIPA {
                    Text(ipa)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section(header: Text("簽名")) {
                Button(action: {}) {
                    HStack {
                        Spacer()
                        Text(isSigning ? "簽名中..." : "開始簽名")
                            .foregroundColor(isSigning ? .secondary : .teal)
                        Spacer()
                    }
                }
                .disabled(isSigning || selectedIPA == nil)
            }
            
            if !progress.isEmpty {
                Section(header: Text("進度")) {
                    Text(progress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("簽名 IPA")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 證書管理頁（UI 空殼，後端待接）
struct CertificateView: View {
    var body: some View {
        List {
            Section(header: Text("證書")) {
                Text("暫無證書")
                    .foregroundColor(.secondary)
            }
            
            Section {
                Button("創建證書") {}
                    .foregroundColor(.teal)
            }
        }
        .navigationTitle("證書管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}
