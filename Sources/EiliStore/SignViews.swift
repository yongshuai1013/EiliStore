import SwiftUI

/// Apple ID 登入頁（UI 空殼，後端待接）
struct SignInView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var isLoading = false
    
    var body: some View {
        Form {
            Section(header: Text("Apple ID")) {
                TextField("Apple ID", text: $appleID)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                SecureField("密碼", text: $password)
                    .textContentType(.password)
            }
            
            Section {
                Button(action: {}) {
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
            
            Section(header: Text("說明")) {
                Text("登入後可用於簽名 IPA。帳號信息保存在 Keychain。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Apple ID 登入")
        .navigationBarTitleDisplayMode(.inline)
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
