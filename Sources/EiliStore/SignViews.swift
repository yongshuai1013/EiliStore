import SwiftUI
import SideSign
import UniformTypeIdentifiers

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

/// Owns only an imported copy. An in-flight task retains it across navigation.
private final class ImportedIPASelection: Sendable {
    let file: ImportedIPAFile
    let info: IPAParser.AppInfo
    init(file: ImportedIPAFile, info: IPAParser.AppInfo) {
        self.file = file
        self.info = info
    }
    deinit { IPAImportStore.remove(file) }
}

/// 匯入本地 IPA，沿用軟體源的簽名與安裝流程。
@MainActor
struct SignIPAView: View {
    @StateObject private var installer = SourceAppInstaller.shared
    @State private var selectedIPA: ImportedIPASelection?
    @State private var showFilePicker = false
    @State private var isImporting = false
    @State private var isVisible = false
    @State private var importMessage: String?
    
    var body: some View {
        List {
            Section("IPA 文件") {
                Button("選擇 IPA") { showFilePicker = true }
                    .disabled(isImporting || installer.isWorking)
                    .accessibilityIdentifier("ipa-file-picker")
                if let selection = selectedIPA {
                    Text(selection.file.originalFilename)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(selection.info.name).font(.headline)
                    Text(selection.info.bundleId).font(.caption).textSelection(.enabled)
                    Text("版本 \(selection.info.version)").font(.caption).foregroundColor(.secondary)
                }
                if isImporting { ProgressView("正在匯入與驗證...") }
                if let message = importMessage {
                    Text(message).font(.caption).foregroundColor(.red)
                }
            }
            
            Section("簽名並安裝") {
                Button(installer.isWorking ? "正在處理..." : "開始簽名並安裝", action: startInstall)
                    .disabled(isImporting || installer.isWorking || selectedIPA == nil)
                    .accessibilityIdentifier("ipa-start-install")
                Text("沿用已登入帳號的第一個開發者 Team 與活動證書。按下開始後才會簽名及安裝；匯入本身不會登入、佈建或安裝。")
                    .font(.caption).foregroundColor(.secondary)
            }
            
            if !installer.statusMessage.isEmpty {
                Section("共用安裝進度") {
                    Text(installer.statusMessage).font(.caption).foregroundColor(.secondary)
                    if installer.isWorking {
                        if installer.progress >= 0 {
                            ProgressView(value: min(1, max(0, installer.progress)))
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
        }
        .navigationTitle("匯入 IPA 並安裝")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ipa-import-page")
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; selectedIPA = nil }
        // File providers may label IPA archives as packages or dynamic types,
        // not public.data. Selection is broad; stage/parser validation is not.
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): importIPA(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    importMessage = "無法選取檔案：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importIPA(_ url: URL) {
        guard !isImporting, !installer.isWorking else { return }
        isImporting = true
        selectedIPA = nil
        importMessage = nil
        Task {
            defer { isImporting = false }
            do {
                let selection = try await Task.detached(priority: .userInitiated) {
                    let file = try IPAImportStore.stage(url)
                    do {
                        let info = try IPAParser.parse(ipaURL: file.url, requireInstallableMetadata: true)
                        return ImportedIPASelection(file: file, info: info)
                    } catch {
                        IPAImportStore.remove(file)
                        throw error
                    }
                }.value
                if isVisible { selectedIPA = selection }
            } catch {
                importMessage = "匯入失敗：\(error.localizedDescription)"
            }
        }
    }

    private func startInstall() {
        guard let selection = selectedIPA, !installer.isWorking, !isImporting else { return }
        Task {
            defer { withExtendedLifetime(selection) {} }
            await installer.installImportedIPA(at: selection.file.url)
        }
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
