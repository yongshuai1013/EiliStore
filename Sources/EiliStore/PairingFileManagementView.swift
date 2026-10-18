import SwiftUI
import UniformTypeIdentifiers

struct PairingFileManagementView: View {
    @ObservedObject private var manager = AppManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var files: [PairingFileInfo] = []
    @State private var preferredProtocol: PairingType?
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
                PairingDetailRow(label: "使用中的協定", value: files.contains(where: \.isSelected) ? "Lockdown" : "無")
                Picker("偏好協定", selection: Binding(
                    get: { preferredProtocol },
                    set: { value in
                        do {
                            try store.setPreferredProtocol(value)
                            preferredProtocol = value
                        } catch {
                            message = "無法儲存偏好協定。"
                        }
                    }
                )) {
                    Text("自動（無偏好）").tag(Optional<PairingType>.none)
                    Text("Lockdown").tag(Optional(PairingType.lockdown))
                }
                .disabled(isBusy)
            } header: {
                Text("協定狀態")
            } footer: {
                Text("顯示目前引擎可使用的配對協定，不代表 VPN 已連線或配對握手成功。目前引擎只支援 Lockdown；Remote 不會被自動選用。")
            }

            Section {
                ForEach(files) { file in
                    NavigationLink {
                        PairingFileDetailView(file: file)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: file.type == .lockdown ? "lock.shield" : "waveform.circle")
                                .foregroundColor(file.isSelected ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.id.hasPrefix("legacy-") ? file.fileName : "\(file.type.title) 配對檔")
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
                Text("配對憑證及裝置識別資料不會顯示或提供複製、分享。Remote 檔案僅列出儲存狀態，目前不支援匯入、驗證或使用。")
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
        .fileImporter(isPresented: $isPickingLockdown, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                guard !isBusy else {
                    message = "安裝或刷新正在進行，請完成後再匯入。"
                    return
                }
                updatePairing {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try store.importLockdown(from: url)
                }
            case .failure:
                message = "未匯入檔案，現有配對檔未變更。"
            }
        }
    }

    private func status(for file: PairingFileInfo) -> String {
        guard file.isInstalled else { return "未安裝" }
        if file.type == .remote { return "已儲存 · 引擎不支援" }
        return file.isStructurallyValid ? "已安裝 · 結構檢查通過" : "無法使用 · 請重新匯入"
    }

    private func reload() {
        files = store.inventory()
        preferredProtocol = store.preferredProtocol
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

private struct PairingFileDetailView: View {
    let file: PairingFileInfo

    var body: some View {
        List {
            Section("檔案資料") {
                PairingDetailRow(label: "檔案名稱", value: file.fileName)
                PairingDetailRow(label: "類型", value: file.type.title)
                PairingDetailRow(label: "安裝狀態", value: file.isInstalled ? "已安裝" : "未安裝")
                PairingDetailRow(label: "使用狀態", value: file.isSelected ? "使用中（不代表連線成功）" : "未使用")
                if file.isInstalled {
                    PairingDetailRow(label: "驗證狀態", value: file.type == .remote ? "不支援驗證" :
                        (file.isStructurallyValid ? "結構檢查通過" : "結構無效或無法讀取"))
                    PairingDetailRow(label: "大小", value: file.fileSize.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "無法取得")
                    PairingDetailRow(label: "建立時間", value: date(file.dateCreated))
                    PairingDetailRow(label: "修改時間", value: date(file.dateModified))
                }
            }
            Section {
                ForEach(file.presentSensitiveFields, id: \.self) { field in
                    PairingDetailRow(label: field, value: "已隱藏")
                }
                Text("私鑰、憑證、HostID、SystemBUID、UDID 及其他配對憑證一律隱藏，不提供揭露、複製或匯出。舊版檔名亦會隱藏，避免洩漏裝置識別資料。")
                    .font(.footnote).foregroundColor(.secondary)
            } header: {
                Text("私隱保護")
            } footer: {
                Text("結構檢查只確認必要欄位存在，並非私鑰有效性或裝置信任驗證；實際連線仍由現有 Rust 引擎處理。")
            }
        }
        .navigationTitle("配對檔詳情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func date(_ date: Date?) -> String {
        guard let date else { return "無法取得" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct WirelessPairingAvailabilityView: View {
    let onImport: () -> Void

    var body: some View {
        List {
            Section("無線配對狀態") {
                Label("此版本尚未支援 App 內無線配對", systemImage: "wifi.slash")
                Text("現有 Rust 連線引擎使用已匯入的 Lockdown 配對檔，未接入 SideStore 的無線配對廣播、PIN 驗證與握手流程。這裡不會開始配對，也不會切換至 Remote 協定。")
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
