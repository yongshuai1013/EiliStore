import SwiftUI
import UniformTypeIdentifiers

struct PairingFileManagementView: View {
    @ObservedObject private var manager = AppManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [PairingFileInfo] = []
    @State private var preferredProtocol: PairingType?
    @State private var remotePortText = "49152"
    @State private var isPickingLockdown = false
    @State private var isUpdating = false
    @State private var message: String?
    @State private var pendingAction: ManagementAction?
    @State private var showConfirmation = false

    private let store = PairingFileStore.shared

    private enum ManagementAction {
        case replace, delete(PairingType), reset

        var explanation: String {
            switch self {
            case .replace: return "選擇並驗證新檔案後，才會替換目前的 Lockdown 配對檔。現有心跳服務會停止，完成後請重新啟動 App。"
            case .delete: return "刪除這個配對檔會停止心跳服務。若有有效的舊版 Lockdown 檔案，系統會改用它。此操作無法復原。"
            case .reset: return "這會停止心跳服務，移除所有已儲存的 Lockdown、Remote 及舊版配對檔，並清除偏好協定。完成後需要重新匯入並重新啟動 App。此操作無法復原。"
            }
        }
    }

    private var isBusy: Bool {
        isUpdating || manager.isRefreshing || manager.isRefreshingExternal || RustFFILock.shared.isTransferActive
    }

    var body: some View {
        List {
            Section {
                PairingDetailRow(label: "選用協定", value: files.first(where: \.isSelected)?.type.title ?? "無")
                Picker("偏好協定", selection: Binding(
                    get: { preferredProtocol },
                    set: { value in
                        updatePairing { try store.setPreferredProtocol(value) }
                    }
                )) {
                    Text("自動（無偏好）").tag(Optional<PairingType>.none)
                    Text("Lockdown").tag(Optional(PairingType.lockdown))
                    if files.contains(where: { $0.type == .remote && $0.isStructurallyValid }) {
                        Text("Remote Pairing").tag(Optional(PairingType.remote))
                    }
                }
                .disabled(isBusy)
            } header: {
                Text("協定狀態")
            } footer: {
                Text("選用不代表連線或握手成功。自動模式優先使用有效的 Lockdown，其次是已儲存的 Remote。明確選擇的協定不可用時不會切換至另一協定。Remote 只驗證既有配對，不會開始首次配對。切換後請重新啟動 App。")
            }

            Section {
                ForEach(files) { file in
                    NavigationLink {
                        PairingFileDetailView(fileID: file.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: file.type == .lockdown ? "lock.shield" : "waveform.circle")
                                .foregroundColor(file.isSelected ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let name = file.annotation?.displayName, !name.isEmpty {
                                        Text(name)
                                        Text(file.id.hasPrefix("legacy-") ? file.fileName : "\(file.type.title) 配對檔")
                                            .font(.caption).foregroundColor(.secondary)
                                    } else {
                                        Text(file.id.hasPrefix("legacy-") ? file.fileName : "\(file.type.title) 配對檔")
                                    }
                                }
                                Text(status(for: file))
                                    .font(.caption)
                                    .foregroundColor(file.isInstalled ? .secondary : .red)
                            }
                            Spacer()
                            if file.isSelected {
                                Text("使用中").font(.caption).foregroundColor(.green)
                            }
                        }
                    }
                }
                Button {
                    requestImport()
                } label: {
                    Label("匯入／替換 Lockdown 配對檔", systemImage: "square.and.arrow.down")
                }
                .disabled(isBusy)
            } header: {
                Text("配對檔清單")
            } footer: {
                Text("清單與詳情預設隱藏配對憑證及裝置識別資料。明確開啟原始 XML 編輯器後才會在本機顯示內容，不會記錄或上傳。已儲存的 Remote 檔案可做結構檢查並用於既有配對連線；此處不提供 Remote 匯入或 XML 編輯。")
            }

            if files.contains(where: { $0.type == .remote && $0.isInstalled }) {
                Section {
                    TextField("Remote 服務端口", text: $remotePortText)
                        .keyboardType(.numberPad)
                    Button("儲存 Remote 端口") {
                        guard let port = UInt16(remotePortText), port > 0 else {
                            message = "端口必須介於 1 至 65535。"
                            return
                        }
                        updatePairing { UserDefaults.standard.set(Int(port), forKey: "pairing.remotePort") }
                    }
                } header: {
                    Text("既有 Remote 連線")
                } footer: {
                    Text("使用既有裝置 IP 設定及 Remote Pairing TCP 服務端口（預設 49152）。端口必須與裝置實際服務一致；不會啟動配對廣播或 PIN 流程。變更後請重新啟動 App。")
                }
                .disabled(isBusy)
            }

            Section("配對方式") {
                NavigationLink {
                    WirelessPairingAvailabilityView(onImport: requestImport)
                } label: {
                    Label("無線配對", systemImage: "wifi")
                }
            }

            Section {
                ForEach(PairingType.allCases) { type in
                    if files.contains(where: { $0.id == type.rawValue && $0.isInstalled }) {
                        Button(role: .destructive) {
                            confirm(.delete(type))
                        } label: {
                            Label("刪除 \(type.title) 配對檔", systemImage: "trash")
                        }
                        .disabled(isBusy)
                    }
                }
                Button(role: .destructive) {
                    confirm(.reset)
                } label: {
                    Label("重置所有配對檔", systemImage: "exclamationmark.circle")
                }
                .disabled(isBusy || !files.contains(where: \.isInstalled) && preferredProtocol == nil)
            } header: {
                Text("管理")
            } footer: {
                Text("安裝或刷新進行中時不能修改配對檔。重置亦會移除清單中的舊版配對檔，但不會更改 VPN、Apple ID 或簽署設定。")
            }

            if isUpdating {
                ProgressView("正在更新配對檔…")
            }
            if let message {
                Section("操作結果") {
                    Text(message).font(.subheadline)
                }
            }
        }
        .navigationTitle("配對檔管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { phase in
            if phase == .active { reload() }
        }
        .refreshable { reload() }
        .toolbar {
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("重新整理配對檔狀態")
        }
        .alert("確認配對檔操作", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) { pendingAction = nil }
            Button("繼續", role: .destructive) {
                guard let action = pendingAction else { return }
                pendingAction = nil
                switch action {
                case .replace:
                    guard !isBusy else { return }
                    isPickingLockdown = true
                case .delete(let type):
                    updatePairing { try store.delete(type) }
                case .reset:
                    updatePairing { try store.reset() }
                }
            }
        } message: {
            Text(pendingAction?.explanation ?? "")
        }
        .sheet(isPresented: $isPickingLockdown) {
            DocumentPicker(
                onPick: { url in
                    isPickingLockdown = false
                    guard !isBusy else {
                        message = "安裝或刷新正在進行，請完成後再匯入。"
                        return
                    }
                    updatePairing {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try store.importLockdown(from: url)
                    }
                },
                onCancel: {
                    isPickingLockdown = false
                },
                allowedContentTypes: [.item]
            )
        }
    }

    private func status(for file: PairingFileInfo) -> String {
        guard file.isInstalled else { return "未安裝" }
        return file.isStructurallyValid ? "已安裝 · 結構檢查通過" : "無法使用 · 請重新匯入"
    }

    private func reload() {
        files = store.inventory()
        preferredProtocol = store.preferredProtocol
        remotePortText = String(RustDeviceTransport.remotePort)
    }

    private func requestImport() {
        guard !isBusy else { return }
        if files.contains(where: { $0.type == .lockdown && $0.isInstalled }) {
            confirm(.replace)
        } else {
            isPickingLockdown = true
        }
    }

    private func confirm(_ action: ManagementAction) {
        pendingAction = action
        showConfirmation = true
    }

    private func updatePairing(_ operation: @escaping () throws -> Void) {
        guard !isBusy else {
            message = "安裝或刷新正在進行，請稍後再試。"
            return
        }
        isUpdating = true
        message = nil
        Task { @MainActor in
            await HeartbeatManager.shared.stop()
            defer { isUpdating = false; reload() }
            // A refresh may have started while awaiting heartbeat shutdown.
            guard !manager.isRefreshing, !manager.isRefreshingExternal, !RustFFILock.shared.isTransferActive else {
                message = "安裝或刷新正在進行，未修改配對檔。心跳服務已停止，請完成後重新啟動 App。"
                return
            }
            do {
                try operation()
                message = "配對檔已更新。心跳服務已停止，請重新啟動 App 後再使用。"
            } catch let error as PairingStoreError {
                message = (error.errorDescription ?? "無法更新配對檔。") + "\n心跳服務已停止，請重新啟動 App 後再連線。"
            } catch {
                message = "無法更新配對檔，請重新整理後再試。心跳服務已停止，請重新啟動 App 後再連線。"
            }
        }
    }
}

private struct WirelessPairingAvailabilityView: View {
    let onImport: () -> Void

    var body: some View {
        List {
            Section("無線配對狀態") {
                Label("此版本尚未支援 App 內無線配對", systemImage: "wifi.slash")
                Text("現有連線引擎可以使用已儲存的配對檔，但此頁未接入首次無線配對廣播、PIN 驗證與配對建立流程。這裡不會開始配對，也不會切換協定。")
            }
            Section("目前可用的方式") {
                Text("先在可信任的電腦產生此裝置的 Lockdown 配對檔，再匯入本 App。配對檔包含敏感憑證，請勿貼到聊天或公開分享。")
                Button("匯入 Lockdown 配對檔", action: onImport)
            }
        }
        .navigationTitle("無線配對")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PairingDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
