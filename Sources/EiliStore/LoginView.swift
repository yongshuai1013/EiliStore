import SwiftUI
import SideSign

// MARK: - 登入（未登入時從設定頁進入）
@MainActor
struct LoginView: View {
    @Binding var appleID: String
    @Binding var isLoggedIn: Bool

    @State private var password = ""
    @State private var verificationCode = ""
    @State private var errorMessage: String?
    @State private var codeMessage = ""
    @State private var isLoading = false
    @State private var needs2FA = false
    @State private var loginTask: Task<Void, Never>?
    @State private var codeProvider: TwoFACodeProvider?
    @State private var showMethodPicker = false
    @State private var availablePhones: [TrustedPhoneNumber] = []
    @State private var preferredMethod: TwoFactorDeliveryMode = .sms
    @State private var debugLog = ""

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog += "[\(timestamp)] \(message)\n"
    }

    var body: some View {
        Form {
            Section(header: Text("Apple ID 登入（SideSign）")) {
                TextField("Apple ID", text: $appleID)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .disabled(isLoading)
                SecureField("密碼", text: $password)
                    .disabled(isLoading)

                if needs2FA {
                    Text(codeMessage)
                        .font(.caption)
                    TextField("6 位驗證碼", text: $verificationCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("提交驗證碼") {
                        codeProvider?.submitCode(verificationCode)
                        verificationCode = ""
                        needs2FA = false
                        codeMessage = ""
                        errorMessage = nil
                    }
                    .disabled(!TwoFACodeProvider.isValidCode(verificationCode))
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Button(action: doLogin) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("登入")
                    }
                }
                .disabled(isLoading || appleID.isEmpty || password.isEmpty)
                if isLoading {
                    Button("取消登入", role: .cancel) { cancelLogin() }
                }
            }

            Section(footer: Text("VPN 外置：請確保外部 VPN 已連接（10.7.0.1 可達）")) {
                NavigationLink(destination: AnisetteServerView()) {
                    HStack {
                        Text("Anisette 伺服器")
                        Spacer()
                        Text(AnisetteServerManager.shared.selectedServer.name)
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                }
                .disabled(isLoading)
                Button("Reset Anisette（清除本地數據）") {
                    PaxAuthService.shared.resetAnisette()
                    log("已清除 Anisette 本地數據")
                    errorMessage = "Anisette 數據已清除，下次登入會重新生成"
                }
                .foregroundColor(.red)
                .disabled(isLoading)
            }

            Section(
                header: Text("Session 二維碼"),
                footer: Text("透過二維碼在設備間移轉已保存的登入 Session；請勿分享二維碼。")
            ) {
                NavigationLink(destination: SessionQRView()) {
                    HStack {
                        Text("導出/導入 Session")
                        Spacer()
                        Image(systemName: "qrcode")
                            .foregroundColor(.teal)
                    }
                }
                .disabled(isLoading)
            }

            if !debugLog.isEmpty {
                Section(header: Text("調試日誌")) {
                    ScrollView {
                        Text(debugLog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    Button("清除日誌") { debugLog = "" }
                        .font(.caption)
                }
            }
        }
        .navigationTitle("登入")
        .onDisappear { cancelLogin(showMessage: false) }
        .actionSheet(isPresented: $showMethodPicker) {
            let provider = codeProvider
            var buttons: [ActionSheet.Button] = []
            buttons.append(.default(Text(preferredMethod == .trustedDevice ? "受信任設備（建議）" : "受信任設備")) {
                provider?.submitMethod(.trustedDevice)
            })
            for phone in availablePhones {
                let label = phone.number.isEmpty ? "受信任電話" : phone.number
                buttons.append(.default(Text("SMS: \(label)")) {
                    provider?.submitMethod(.sms(phoneID: phone.id))
                })
                buttons.append(.default(Text("語音電話: \(label)")) {
                    provider?.submitMethod(.voice(phoneID: phone.id))
                })
            }
            // Apple 沒提供清單時，SideSign 使用 id=1 作為預設電話；並非已確認的號碼。
            if availablePhones.isEmpty {
                buttons.append(.default(Text("SMS（Apple 預設電話）")) {
                    provider?.submitMethod(.sms(phoneID: "1"))
                })
                buttons.append(.default(Text("語音（Apple 預設電話）")) {
                    provider?.submitMethod(.voice(phoneID: "1"))
                })
            }
            buttons.append(.cancel(Text("取消登入")) {
                guard let provider, codeProvider === provider else { return }
                cancelLogin()
            })
            return ActionSheet(
                title: Text("選擇驗證方式"),
                message: Text("選擇後才會向 Apple 要求驗證碼；請避免連續重發。"),
                buttons: buttons
            )
        }
    }

    private func doLogin() {
        guard !isLoading else { return }
        let provider = TwoFACodeProvider()
        codeProvider = provider
        isLoading = true
        errorMessage = nil
        needs2FA = false
        verificationCode = ""
        codeMessage = ""
        debugLog = ""

        provider.onCodeRequired = { [weak provider] mode, rejected in
            Task { @MainActor in
                guard let provider, codeProvider === provider, !provider.isCancelled else { return }
                verificationCode = ""
                showMethodPicker = false
                availablePhones = []
                needs2FA = true
                switch mode {
                case .trustedDevice:
                    codeMessage = "請查看受信任 Apple 設備上的驗證碼。"
                case .sms:
                    codeMessage = "Apple 已接受簡訊發送請求，請查看受信任電話。"
                case .voice:
                    codeMessage = "Apple 已接受語音來電請求，請留意受信任電話。"
                }
                errorMessage = rejected ? "驗證碼未被接受或已過期，請重新輸入；本次沒有重發驗證碼。" : nil
            }
        }
        provider.onMethodRequired = { [weak provider] phones, preferred in
            Task { @MainActor in
                guard let provider, codeProvider === provider, !provider.isCancelled else { return }
                availablePhones = phones
                preferredMethod = preferred
                showMethodPicker = true
            }
        }
        provider.onLog = { [weak provider] message in
            Task { @MainActor in
                guard let provider, codeProvider === provider else { return }
                log(message)
            }
        }

        loginTask = Task { @MainActor in
            defer {
                provider.cancel()
                if codeProvider === provider { finishLogin() }
            }
            do {
                log("開始登入")
                let success = try await PaxAuthService.shared.login(
                    appleID: appleID,
                    password: password,
                    codeProvider: provider
                )
                try Task.checkCancellation()
                guard codeProvider === provider else { return }
                if success {
                    isLoggedIn = true
                    log("登入成功")
                } else {
                    errorMessage = "登入未完成，請稍後再試。"
                }
            } catch {
                guard codeProvider === provider else { return }
                let message = PaxAuthService.loginErrorMessage(for: error)
                errorMessage = message
                log(message)
            }
        }
    }

    private func finishLogin() {
        codeProvider = nil
        loginTask = nil
        isLoading = false
        needs2FA = false
        showMethodPicker = false
        availablePhones = []
        verificationCode = ""
        codeMessage = ""
        password = ""
    }

    private func cancelLogin(showMessage: Bool = true) {
        guard isLoading else { return }
        loginTask?.cancel()
        codeProvider?.cancel()
        finishLogin()
        errorMessage = showMessage ? "登入已取消" : nil
    }
}

// MARK: - 已登入時的賬號頁
struct AccountView: View {
    @Binding var appleID: String
    @Binding var isLoggedIn: Bool
    @State private var showLogoutAlert = false
    @State private var sessionStatus: String? = nil
    @State private var sessionValid: Bool? = nil
    @State private var isChecking = false
    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        return f
    }

    var body: some View {
        List {
            Section(header: Text("賬號")) {
                HStack {
                    Text("Apple ID")
                    Spacer()
                    Text(appleID)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Session 狀態")
                    Spacer()
                    if isChecking {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if let valid = sessionValid {
                        Text(valid ? "有效" : "已失效")
                            .foregroundColor(valid ? .green : .red)
                            .bold()
                    } else {
                        Text("未知")
                            .foregroundColor(.secondary)
                    }
                }
                if let status = sessionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button(action: { checkSession() }) {
                    Text("檢查登入狀態")
                }
                .disabled(isChecking)
                HStack {
                    Text("Session 寫入時間")
                    Spacer()
                    if let date = KeychainHelper.sessionCreationDate() {
                        Text(dateFormatter.string(from: date))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        Text("無記錄")
                            .foregroundColor(.secondary)
                    }
                }
            }
            Section(header: Text("Developer Portal Services")) {
                NavigationLink(destination: DeveloperPortalView()) {
                    Label("Developer Portal", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            Section(
                header: Text("Session 二維碼"),
                footer: Text("導出備份後，可在更換設備時掃描導入。二維碼包含敏感登入資料，請妥善保管。")
            ) {
                NavigationLink(destination: SessionQRView()) {
                    HStack {
                        Text("導出/導入 Session")
                        Spacer()
                        Image(systemName: "qrcode")
                            .foregroundColor(.teal)
                    }
                }
            }

            Section(footer: Text("登出會清除本地登入狀態，下次登入需要重新驗證。")) {
                Button("登出") {
                    showLogoutAlert = true
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("賬號")
        .onAppear { checkSession() }
        .alert("確定要登出嗎？", isPresented: $showLogoutAlert) {
            Button("登出", role: .destructive) {
                PaxAuthService.shared.logout()
                appleID = ""
                isLoggedIn = false
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("登出後若 Apple 暫時限制登入，可能無法立即重新登入。")
        }
    }

    /// 檢查 session 是否有效（調用輕量 API）
    private func checkSession() {
        guard !isChecking else { return }
        isChecking = true
        sessionStatus = nil
        Task {
            do {
                let teams = try await PaxSigningService.shared.fetchTeams()
                await MainActor.run {
                    self.sessionValid = true
                    self.sessionStatus = "Session 有效，找到 \(teams.count) 個 Team"
                    self.isChecking = false
                }
            } catch {
                await MainActor.run {
                    self.sessionValid = false
                    self.sessionStatus = "Session 已失效: \(error.localizedDescription)"
                    self.isChecking = false
                }
            }
        }
    }
}
