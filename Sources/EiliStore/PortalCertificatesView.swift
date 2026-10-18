import SwiftUI
import SideSign

@MainActor
struct PortalCertificatesView: View {
    @ObservedObject var model: DeveloperPortalModel
    @State private var search = ""
    private var filtered: [SideSign.X509Certificate] {
        model.certificates.filter { search.isEmpty || ($0.machineName ?? $0.name).localizedCaseInsensitiveContains(search) || $0.serialNumberHex.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            PortalStatusSection(model: model)
            Section(header: Text("Certificates (\(model.certificates.count))"), footer: Text("這是所選團隊在 Apple Portal 的證書；遠端證書不代表此裝置持有對應私鑰。撤銷會影響相關簽名與描述檔。")) {
                if filtered.isEmpty { Text(model.sectionErrors["certificates"] == nil ? "沒有符合的證書" : "證書尚未成功載入").foregroundColor(.secondary) }
                ForEach(filtered, id: \.serialNumberHex) { cert in
                    NavigationLink(destination: PortalCertificateDetailView(model: model, serial: cert.serialNumberHex)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cert.machineName ?? cert.name)
                            Text(cert.serialNumberHex).font(.caption).foregroundColor(.secondary)
                            if let expiry = cert.notAfter { Text("到期日：\(expiry.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Certificates")
        .searchable(text: $search, prompt: "名稱或證書序號")
        .refreshable { await model.refresh() }
        .disabled(model.isActing || model.isLoading)
    }
}

@MainActor
private struct PortalCertificateDetailView: View {
    @ObservedObject var model: DeveloperPortalModel
    let serial: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRevoke = false
    private var certificate: SideSign.X509Certificate? { model.certificates.first { $0.serialNumberHex == serial } }
    private var active: Bool { PaxSigningService.shared.loadActiveCertificateSerial() == serial }
    var body: some View {
        List {
            PortalStatusSection(model: model)
            if let cert = certificate {
                Section("Certificate Details") {
                    PortalInfoRow(title: "名稱", value: cert.machineName ?? cert.name)
                    PortalInfoRow(title: "序號", value: cert.serialNumberHex)
                    PortalInfoRow(title: "Portal ID", value: cert.identifier ?? "未提供")
                    PortalInfoRow(title: "狀態", value: cert.status ?? "未提供")
                    PortalInfoRow(title: "類型", value: cert.certificateTypeName ?? cert.certificateType ?? "未提供")
                    PortalInfoRow(title: "平台", value: cert.platformName ?? cert.platform ?? "未提供")
                    if let created = cert.notBefore { Text("建立日期：\(created.formatted(date: .abbreviated, time: .omitted))") }
                    if let expiry = cert.notAfter { Text("到期日期：\(expiry.formatted(date: .abbreviated, time: .omitted))") }
                    Text(active ? "本機持有活動簽名證書" : "此證書未設為本機活動證書").font(.caption).foregroundColor(.secondary)
                    NavigationLink("完整 X.509 資訊", destination: CertificateDetailView(cert: cert, hasPrivateKey: active))
                }
                Section(footer: Text("撤銷永久使此證書失效。只與此證書綁定的描述檔需重新產生，已簽名 App 可能無法繼續使用。")) {
                    Button("撤銷證書", role: .destructive) { confirmRevoke = true }
                }
            } else { Text("此證書已移除或尚未載入。") }
        }
        .navigationTitle("證書詳情")
        .disabled(model.isActing || model.isLoading)
        .alert("永久撤銷證書？", isPresented: $confirmRevoke) {
            Button("取消", role: .cancel) { }
            Button("撤銷", role: .destructive) {
                guard let cert = certificate, let expectedTeam = model.team?.identifier else { return }
                Task {
                    let success = await model.execute { team in
                        guard team.identifier == expectedTeam else { throw PortalResourceViewError.teamChanged }
                        try await PaxSigningService.shared.revokeCertificate(cert, for: team)
                        if PaxSigningService.shared.loadActiveCertificateSerial() == cert.serialNumberHex {
                            PaxSigningService.shared.clearActiveCertificate()
                        }
                    }
                    if success { dismiss() }
                }
            }
        } message: { Text("將撤銷 \(certificate?.machineName ?? serial)。此操作無法復原；若是本機活動證書，也會一併清除本機活動狀態。") }
    }
}
