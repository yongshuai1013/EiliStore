import SwiftUI
import SideSign

/// 保留舊入口，但共用可取消的登入流程，避免兩套 2FA 行為分歧。
@MainActor
struct SignInView: View {
    @State private var appleID = ""
    @State private var isLoggedIn = false

    var body: some View {
        Group {
            if isLoggedIn {
                AccountView(appleID: $appleID, isLoggedIn: $isLoggedIn)
            } else {
                LoginView(appleID: $appleID, isLoggedIn: $isLoggedIn)
            }
        }
        .onAppear {
            if PaxAuthService.shared.hasSavedSession,
               let savedID = PaxAuthService.shared.currentAppleID, !savedID.isEmpty {
                appleID = savedID
                isLoggedIn = true
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
    @State private var activeCertSerial: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var certToRevoke: SideSign.X509Certificate?
    @State private var showRevokeAlert = false
    @StateObject private var logger = AppLogger.shared

    var body: some View {
        List {
            Section(header: Text("TEAM")) {
                if teams.isEmpty {
                    Text(isLoading ? "載入中..." : "無")
                } else {
                    ForEach(teams, id: \.identifier) { team in
                        Button(action: {
                            selectedTeam = team
                            loadCertificates(for: team)
                        }) {
                            HStack {
                                Text(team.name)
                                Spacer()
                                if selectedTeam?.identifier == team.identifier {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.teal)
                                }
                            }
                        }
                    }
                }
            }

            if let serial = activeCertSerial {
                Section(header: Text("ACTIVE LOCAL CERTIFICATE")) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text("Active Signing Certificate")
                                .font(.headline)
                            Text("SN: \(serial)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    Button("Deactivate Locally") {
                        PaxSigningService.shared.clearActiveCertificate()
                        activeCertSerial = nil
                        logger.log("已停用本地活動證書")
                    }
                    .foregroundColor(.red)
                }
            }

            Section(header: Text("CERTIFICATES")) {
                Button("創建新證書") {
                    createCertificate()
                }
                .disabled(isLoading || selectedTeam == nil)
                if certificates.isEmpty {
                    Text(isLoading ? "載入中..." : "無")
                } else {
                    ForEach(certificates, id: \.serialNumberHex) { cert in
                        let hasKey = (cert.serialNumberHex == activeCertSerial)
                        NavigationLink(destination: CertificateDetailView(cert: cert, hasPrivateKey: hasKey)) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(cert.machineName ?? "Unknown")
                                    Text(cert.serialNumberHex)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: hasKey ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(hasKey ? .green : .red)
                            }
                        }
                        .contextMenu {
                            Button("撤銷證書", role: .destructive) {
                                certToRevoke = cert
                                showRevokeAlert = true
                            }
                        }
                    }
                }
            }

            if let error = errorMessage {
                Section(header: Text("錯誤")) {
                    Text(error).foregroundColor(.red)
                }
            }

            Section("說明") {
                Text("證書用於簽名 IPA。免費帳號最多 3 個證書。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("證書管理")
        .onAppear {
            activeCertSerial = PaxSigningService.shared.loadActiveCertificateSerial()
            loadTeams()
        }
        .alert("撤銷證書？", isPresented: $showRevokeAlert) {
            Button("撤銷", role: .destructive) {
                if let cert = certToRevoke, let team = selectedTeam {
                    revokeCertificate(cert, for: team)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            if let cert = certToRevoke {
                Text("確定要撤銷 \(cert.machineName ?? cert.serialNumberHex) 嗎？此操作不可恢復。")
            }
        }
    }

    private func loadTeams() {
        isLoading = true
        Task {
            do {
                let result = try await PaxSigningService.shared.fetchTeams()
                await MainActor.run {
                    self.teams = result
                    self.isLoading = false
                    if let first = result.first {
                        self.selectedTeam = first
                        self.loadCertificates(for: first)
                    }
                    logger.log("加載 \(result.count) 個 Team")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    logger.log("❌ 加載 Team 失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadCertificates(for team: SideSign.Team) {
        isLoading = true
        Task {
            do {
                let result = try await PaxSigningService.shared.fetchCertificates(for: team)
                await MainActor.run {
                    self.certificates = result
                    self.isLoading = false
                    logger.log("加載 \(result.count) 個證書")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    logger.log("❌ 加載證書失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private func revokeCertificate(_ cert: SideSign.X509Certificate, for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await PaxSigningService.shared.revokeCertificate(cert, for: team)
                let wasActive = (cert.serialNumberHex == activeCertSerial)
                await MainActor.run {
                    self.isLoading = false
                    if wasActive {
                        PaxSigningService.shared.clearActiveCertificate()
                        self.activeCertSerial = nil
                    }
                    logger.log("已撤銷證書: \(cert.serialNumberHex)")
                }
                loadCertificates(for: team)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    logger.log("❌ 撤銷證書失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    private func createCertificate() {
        guard let team = selectedTeam else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let keyStore = try await PaxSigningService.shared.createCertificate(for: team, machineName: "EiliStore")
                await MainActor.run {
                    self.activeCertSerial = keyStore.certificate.serialNumberHex
                    self.isLoading = false
                    logger.log("✅ 證書創建成功，已設為活動證書")
                }
                loadCertificates(for: team)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    logger.log("❌ 創建證書失敗: \(error.localizedDescription)")
                }
            }
        }
    }
}

