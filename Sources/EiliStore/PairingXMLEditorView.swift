import SwiftUI

struct PairingXMLEditorView: View {
    let document: PairingXMLDocument
    let onSaved: () -> Void

    @ObservedObject private var manager = AppManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.presentationMode) private var presentationMode
    @State private var draft: String
    @State private var isSaving = false
    @State private var showSaveConfirmation = false
    @State private var showCancelConfirmation = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var heartbeatWasStopped = false

    private let store = PairingFileStore.shared

    init(document: PairingXMLDocument, onSaved: @escaping () -> Void) {
        self.document = document
        self.onSaved = onSaved
        _draft = State(initialValue: document.text)
    }

    private var isDirty: Bool { draft != document.text }
    private var isBusy: Bool {
        isSaving || manager.isRefreshing || manager.isRefreshingExternal || RustFFILock.shared.isTransferActive
    }
    private var isPrivateContentHidden: Bool { scenePhase != .active }
    private var utf8ByteCount: Int { draft.lengthOfBytes(using: .utf8) }
    private var exceedsSizeLimit: Bool { utf8ByteCount > PairingFileStore.maximumFileSize }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(document.type.title + " · 原始 XML")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(utf8ByteCount), countStyle: .file))
                        .font(.caption.monospacedDigit()).foregroundColor(exceedsSizeLimit ? .red : .secondary)
                }
                if document.isConvertedToXML {
                    Text("原始 plist 已轉換為 UTF-8 XML 供編輯；儲存後檔案格式或編碼會改變。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                ZStack {
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("原始配對 XML 編輯器")
                        .privacySensitive()
                        .disabled(isSaving || isPrivateContentHidden)
                        .accessibilityHidden(isPrivateContentHidden)
                    if isPrivateContentHidden {
                        Rectangle().fill(Color(.systemBackground)).overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "eye.slash").font(.title2)
                                Text("私密 XML 已隱藏；返回 App 後可繼續編輯。")
                                    .font(.subheadline).multilineTextAlignment(.center)
                            }
                            .foregroundColor(.secondary).padding()
                        }
                        .accessibilityHidden(true)
                    }
                }
                Text("XML 包含私鑰及憑證等私密資料。草稿只存於記憶體，不會記錄或上傳；沒有額外的複製、分享或匯出按鈕。背景遮罩不保證防止截圖。")
                    .font(.footnote).foregroundColor(.secondary)
                if exceedsSizeLimit {
                    Text("內容超過允許的 \(ByteCountFormatter.string(fromByteCount: Int64(PairingFileStore.maximumFileSize), countStyle: .file)) 上限，不能儲存。")
                        .font(.footnote).foregroundColor(.red)
                }
                if let status = busyStatus {
                    Text(status).font(.footnote).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .navigationTitle("原始配對 XML")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button("取消") {
                        if isDirty { showCancelConfirmation = true } else { close() }
                    }
                    .disabled(isSaving)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("儲存") { showSaveConfirmation = true }
                        .disabled(isBusy || !isDirty || exceedsSizeLimit || document.type != .lockdown)
                }
            }
            .alert("替換原始配對檔？", isPresented: $showSaveConfirmation) {
                Button("返回編輯", role: .cancel) { }
                Button("替換配對檔", role: .destructive) { save() }
            } message: {
                Text("將以目前內容替換原始配對檔。儲存前會先驗證 XML；儲存前會停止心跳，因此可能中斷連線。成功後必須重新啟動 App 才能重新連線。")
            }
            .alert("放棄未儲存的變更？", isPresented: $showCancelConfirmation) {
                Button("繼續編輯", role: .cancel) { }
                Button("放棄變更", role: .destructive) { close() }
            } message: {
                Text("目前的 XML 草稿尚未儲存。")
            }
            .alert("無法儲存原始配對檔", isPresented: $showError) {
                Button("好", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
        .interactiveDismissDisabled(isDirty || isSaving)
        .privacySensitive()
        .onDisappear { draft = "" }
    }

    private var busyStatus: String? {
        guard isBusy else { return nil }
        return isSaving ? "正在驗證並儲存 XML…" : "安裝、刷新或傳輸進行中，暫時不能儲存。"
    }

    private func save() {
        guard !isBusy else {
            errorMessage = "安裝、刷新或傳輸進行中，未儲存 XML。請稍後重試。"
            showError = true
            return
        }
        guard document.type == .lockdown, !exceedsSizeLimit else { return }
        isSaving = true
        Task { @MainActor in
            do {
                // Validate before disrupting the active connection.
                try store.validateXML(draft, for: document.type)
                guard !manager.isRefreshing, !manager.isRefreshingExternal,
                      !RustFFILock.shared.isTransferActive else {
                    isSaving = false
                    errorMessage = "安裝、刷新或傳輸已開始；心跳未停止，未儲存。請稍後重試。"
                    showError = true
                    return
                }
                await HeartbeatManager.shared.stop()
                heartbeatWasStopped = true
                guard !manager.isRefreshing, !manager.isRefreshingExternal,
                      !RustFFILock.shared.isTransferActive else {
                    isSaving = false
                    errorMessage = "心跳已停止，但安裝、刷新或傳輸正在進行；未儲存。請重新啟動 App 前先確認配對檔狀態。"
                    showError = true
                    return
                }
                try saveWhileTransportIdle()
                isSaving = false
                onSaved()
                presentationMode.wrappedValue.dismiss()
            } catch let error as PairingStoreError {
                isSaving = false
                errorMessage = (error.errorDescription ?? "無法安全儲存原始配對檔。") +
                    (heartbeatWasStopped ? "\n\n心跳已停止，請重新啟動 App 以重新連線。" : "")
                showError = true
            } catch {
                isSaving = false
                errorMessage = "無法安全儲存原始配對檔。草稿仍保留。" +
                    (heartbeatWasStopped ? "心跳已停止，請重新啟動 App 以重新連線。" : "")
                showError = true
            }
        }
    }

    private func saveWhileTransportIdle() throws {
        // Never hold an NSLock across await, and never block the UI waiting for a transfer.
        let transport = RustFFILock.shared
        guard transport.lock.try() else { throw PairingStoreError.xmlBusy }
        defer { transport.lock.unlock() }
        guard !manager.isRefreshing, !manager.isRefreshingExternal, !transport.isTransferActive else {
            throw PairingStoreError.xmlBusy
        }
        try store.saveXML(draft, replacing: document)
    }

    private func close() {
        draft = ""
        presentationMode.wrappedValue.dismiss()
    }
}
