import SwiftUI
import SideSign

/// Apple ID 登入頁
struct SignInView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isLoggedIn = false
    @State private var show2FAPrompt = false
    @State private var twoFACode = ""
    @StateObject private var logger = AppLogger.shared
    @State private var codeProvider: TwoFACodeProvider?
    
    var body: some View {
        Form {
            Section("Apple ID") {
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
            
            Section("說明") {
                Text("登入後可用於簽名 IPA。帳號信息保存在 Keychain。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Apple ID 登入")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if KeychainHelper.loadString(forKey: "paxstore.auth.session") != nil {
                isLoggedIn = true
                appleID = KeychainHelper.loadString(forKey: "paxstore.apple.id") ?? ""
            }
        }
        .alert("輸入驗證碼", isPresented: $show2FAPrompt) {
            TextField("6位驗證碼", text: $twoFACode)
                .keyboardType(.numberPad)
            Button("提交") {
                codeProvider?.submitCode(twoFACode)
                twoFACode = ""
            }
            Button("取消", role: .cancel) {
                // TODO: 取消登入
            }
        } message: {
            Text("請輸入發送到您設備的驗證碼")
        }
    }
    
    private func doLogin() {
        isLoading = true
        errorMessage = nil
        logger.log("開始登入: \(appleID)")
        
        Task {
            do {
                let authService = PaxAuthService.shared
                let provider = TwoFACodeProvider()
                
                // 設置日誌和 2FA 回調
                provider.onLog = { msg in
                    AppLogger.shared.log("[登入] \(msg)")
                }
                provider.onCodeRequired = { [self] in
                    Task { @MainActor in
                        self.codeProvider = provider
                        self.show2FAPrompt = true
                    }
                }
                
                let success = try await authService.login(
                    appleID: appleID,
                    password: password,
                    codeProvider: provider
                )
                
                if success {
                    KeychainHelper.saveString(appleID, forKey: "paxstore.apple.id")
                    await MainActor.run {
                        isLoggedIn = true
                        isLoading = false
                        logger.log("✅ 登入成功: \(appleID)")
                    }
                } else {
                    await MainActor.run {
                        errorMessage = "登入失敗"
                        isLoading = false
                        logger.log("❌ 登入失敗")
                    }
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
            Section("IPA 文件") {
                Button("選擇 IPA") {}
                if let ipa = selectedIPA {
                    Text(ipa)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("簽名") {
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
                Section("進度") {
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

/// 證書管理頁
struct CertificateView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var selectedTeam: SideSign.Team?
    @State private var certificates: [SideSign.X509Certificate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var logger = AppLogger.shared
    
    var body: some View {
        List {
            teamSection
            certSection
            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            actionSection
            infoSection
        }
        .navigationTitle("證書管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadTeams()
        }
    }
    
    private var teamSection: some View {
        Section("Team") {
            if teams.isEmpty {
                Text("加載中...")
                    .foregroundColor(.secondary)
            } else {
                ForEach(teams, id: \.teamId) { team in
                    teamRow(team)
                }
            }
        }
    }
    
    private func teamRow(_ team: SideSign.Team) -> some View {
        Button(action: {
            selectedTeam = team
            loadCertificates()
        }) {
            HStack {
                Text(team.name)
                Spacer()
                if selectedTeam?.teamId == team.teamId {
                    Image(systemName: "checkmark")
                        .foregroundColor(.teal)
                }
            }
        }
    }
    
    private var certSection: some View {
        Section("證書") {
            if isLoading {
                ProgressView()
            } else if certificates.isEmpty {
                Text("暫無證書")
                    .foregroundColor(.secondary)
            } else {
                ForEach(certificates, id: \.serialNumber) { cert in
                    VStack(alignment: .leading) {
                        Text(cert.name ?? "未知")
                            .font(.headline)
                        Text("序列號: \(cert.serialNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    private var actionSection: some View {
        Section {
            Button("創建證書") {
                createCertificate()
            }
            .foregroundColor(.teal)
            .disabled(selectedTeam == nil)
        }
    }
    
    private var infoSection: some View {
        Section("說明") {
            Text("證書用於簽名 IPA。免費帳號最多 3 個證書。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func loadTeams() {
        Task {
            do {
                let fetched = try await PaxSigningService.shared.fetchTeams()
                await MainActor.run {
                    teams = fetched
                    if let first = fetched.first {
                        selectedTeam = first
                        loadCertificates()
                    }
                    logger.log("加載 \(fetched.count) 個 Team")
                }
            } catch {
                await MainActor.run {
                    errorMessage = "加載 Team 失敗: \(error.localizedDescription)"
                    logger.log("❌ 加載 Team 失敗: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func loadCertificates() {
        guard let team = selectedTeam else { return }
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let certs = try await PaxSigningService.shared.fetchCertificates(for: team)
                await MainActor.run {
                    certificates = certs
                    isLoading = false
                    logger.log("加載 \(certs.count) 個證書")
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    logger.log("❌ 加載證書失敗: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func createCertificate() {
        guard let team = selectedTeam else { return }
        
        Task {
            do {
                logger.log("正在創建證書...")
                let keyStore = try await PaxSigningService.shared.createCertificate(for: team)
                PaxSigningService.shared.saveActiveCertificate(keyStore)
                logger.log("✅ 證書創建成功，已設為活動證書")
                loadCertificates()
            } catch {
                await MainActor.run {
                    errorMessage = "創建失敗: \(error.localizedDescription)"
                }
                logger.log("❌ 創建證書失敗: \(error.localizedDescription)")
            }
        }
    }
}
