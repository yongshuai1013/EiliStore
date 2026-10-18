import SwiftUI

struct PairingFileDetailView: View {
    let fileID: String

    @ObservedObject private var manager = AppManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var file: PairingFileInfo?
    @State private var isEditing = false
    @State private var draft = PairingFileAnnotation.empty
    @State private var expected = PairingFileAnnotation.empty
    @State private var showCancelConfirmation = false
    @State private var message: String?
    @State private var isSaving = false
    @State private var showXMLWarning = false
    @State private var xmlDocument: PairingXMLDocument?

    private let store = PairingFileStore.shared

    private var isBusy: Bool {
        isSaving || manager.isRefreshing || manager.isRefreshingExternal || RustFFILock.shared.isTransferActive
    }

    private var validationMessage: String? {
        if draft.displayName.count > PairingFileAnnotation.maximumNameLength {
            return "顯示名稱最多 \(PairingFileAnnotation.maximumNameLength) 字。"
        }
        if draft.note.count > PairingFileAnnotation.maximumNoteLength {
            return "備註最多 \(PairingFileAnnotation.maximumNoteLength) 字。"
        }
        let forbiddenName = draft.displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        let forbiddenNote = draft.note.unicodeScalars.contains {
            CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")).contains($0)
        }
        if forbiddenName { return "顯示名稱不能換行或包含控制字元。" }
        if forbiddenNote { return "備註包含不支援的控制字元。" }
        return nil
    }

    private var isDirty: Bool { (try? draft.validated()) != expected }
    private var canEdit: Bool { file?.canEditAnnotation == true && file?.annotation != nil }

    var body: some View {
        Group {
            if let file {
                detail(file)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.questionmark").font(.largeTitle).foregroundColor(.secondary)
                    Text("配對檔已無法使用").font(.headline)
                    Text("此配對檔已移除或目前無法安全讀取。請返回清單並重新整理。")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    if let message {
                        Text(message).font(.footnote).foregroundColor(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("配對檔詳情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let file, !isEditing, file.canEditAnnotation, file.annotation != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("編輯資訊") { beginEditing(file) }
                        .disabled(isBusy)
                }
            }
            if !isEditing {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: reload) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重新整理配對檔詳情")
                }
            }
            if isEditing {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button("取消") {
                        if isDirty { showCancelConfirmation = true } else { discardEditing() }
                    }
                    .disabled(isSaving)
                    Button("儲存") { save() }
                        .disabled(isBusy || !isDirty || validationMessage != nil || !canEdit)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { reload() }
        }
        .refreshable { if !isEditing { reload() } }
        .alert("放棄未儲存的變更？", isPresented: $showCancelConfirmation) {
            Button("繼續編輯", role: .cancel) { }
            Button("放棄變更", role: .destructive) { discardEditing() }
        } message: {
            Text("目前的顯示名稱或備註尚未儲存。")
        }
        .alert("檢視及編輯原始配對 XML？", isPresented: $showXMLWarning) {
            Button("取消", role: .cancel) { }
            Button("繼續（顯示私密資料）") { openXML() }
        } message: {
            Text("原始 XML 可能包含完整私鑰及憑證，內容只會在此 App 畫面本機顯示，不會記錄或上傳。編輯錯誤可能損壞配對檔並中斷連線。請勿在他人可見的環境操作或複製私密內容。")
        }
        .sheet(item: $xmlDocument, onDismiss: { xmlDocument = nil }) { document in
            PairingXMLEditorView(document: document) {
                xmlDocument = nil
                reload()
                message = "原始配對檔已替換。心跳已停止；請重新啟動 App 以重新連線。"
            }
        }
    }

    @ViewBuilder
    private func detail(_ file: PairingFileInfo) -> some View {
        List {
            Section("檔案資料") {
                PairingDetailRow(label: "檔案名稱", value: file.fileName)
                PairingDetailRow(label: "類型", value: file.type.title)
                PairingDetailRow(label: "安裝狀態", value: file.isInstalled ? "已安裝" : "未安裝")
                PairingDetailRow(label: "使用狀態", value: file.isSelected ? "使用中（不代表連線成功）" : "未使用")
                if file.isInstalled {
                    PairingDetailRow(label: "驗證狀態", value: file.isStructurallyValid ? "結構檢查通過" : "結構無效或無法讀取")
                    PairingDetailRow(label: "大小", value: file.fileSize.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "無法取得")
                    PairingDetailRow(label: "建立時間", value: date(file.dateCreated))
                    PairingDetailRow(label: "修改時間", value: date(file.dateModified))
                }
            }
            Section("原始配對檔") {
                if file.isInstalled && file.type == .lockdown {
                    Button("原始 XML／編輯") { showXMLWarning = true }
                        .disabled(isBusy || isEditing)
                    Text("此選項會在本機顯示並允許編輯原始 Lockdown XML，包括私鑰與憑證；不會自動複製、記錄或上傳。")
                        .font(.footnote).foregroundColor(.secondary)
                } else if file.isInstalled && file.type == .remote {
                    Text("Remote Pairing 原始 XML 編輯不支援；既有 Remote 配對檔可在管理頁選用，結構檢查不代表裝置信任驗證。")
                        .font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("尚未安裝配對檔，無法載入 XML。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            Section {
                if isEditing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("顯示名稱").font(.caption).foregroundColor(.secondary)
                        TextField("選填", text: $draft.displayName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("顯示名稱")
                        Text("最多 60 字；不得換行或包含控制字元。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("備註").font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $draft.note).frame(minHeight: 100)
                            .accessibilityLabel("備註")
                        Text("最多 300 字。請勿輸入真實憑證或裝置識別資料。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let validationMessage {
                        Text(validationMessage).font(.caption).foregroundColor(.red)
                    }
                } else if let annotation = file.annotation {
                    PairingDetailRow(label: "顯示名稱", value: annotation.displayName.isEmpty ? "未設定" : annotation.displayName)
                    PairingDetailRow(label: "備註", value: annotation.note.isEmpty ? "未設定" : annotation.note)
                } else {
                    Text("本機資訊無法讀取，因此不能編輯。")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Text("顯示名稱及備註只存於獨立的私人本機資訊檔，不會更改配對檔、檔名或憑證，亦不會啟用 Remote 協定。匯入替換標準配對檔後仍保留本機標記，刪除或重置時會移除。請勿輸入真實憑證或裝置識別資料。")
                    .font(.footnote).foregroundColor(.secondary)
                if isBusy {
                    Text("安裝、刷新或傳輸進行中，暫時不能儲存本機資訊。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            } header: {
                Text("本機資訊")
            }
            Section {
                ForEach(file.presentSensitiveFields, id: \.self) { field in
                    PairingDetailRow(label: field, value: "已隱藏")
                }
                Text("預設只顯示遮蔽後的敏感欄位中繼資料；只有明確開啟原始 XML 編輯器時，才會在本機畫面揭露 XML 內的私鑰及憑證。App 不會自動複製、記錄或上傳 XML。舊版原始檔名亦不會顯示。")
                    .font(.footnote).foregroundColor(.secondary)
            } header: {
                Text("私隱保護")
            } footer: {
                Text("結構檢查只確認必要欄位存在，並非私鑰有效性或裝置信任驗證；實際連線仍由現有 Rust 引擎處理。")
            }
            if let message {
                Section("操作結果") { Text(message).font(.subheadline) }
            }
        }
        .disabled(isSaving)
    }

    private func beginEditing(_ file: PairingFileInfo) {
        guard !isBusy, file.canEditAnnotation, let annotation = file.annotation else { return }
        expected = annotation
        draft = annotation
        message = nil
        isEditing = true
    }

    private func openXML() {
        guard !isBusy, !isEditing, let file, file.isInstalled, file.type == .lockdown else { return }
        do {
            xmlDocument = try store.loadXML(for: fileID)
        } catch let error as PairingStoreError {
            message = error.errorDescription ?? "無法安全載入原始配對 XML。"
        } catch {
            message = "無法安全載入原始配對 XML。"
        }
    }

    private func discardEditing() {
        isEditing = false
        message = nil
        reload()
    }

    private func save() {
        guard !isBusy, canEdit, let validated = try? draft.validated() else { return }
        isSaving = true
        message = nil
        do {
            try store.updateAnnotation(for: fileID, annotation: validated, expected: expected)
            isEditing = false
            reload()
            message = "本機資訊已儲存，配對檔與憑證未變更。無需重新啟動 App。"
        } catch let error as PairingStoreError {
            message = error.errorDescription ?? "無法儲存本機資訊。"
            if case PairingStoreError.fileMissing = error {
                file = nil
                isEditing = false
            }
        } catch {
            message = "無法儲存本機資訊，請重新整理後再試。"
        }
        isSaving = false
    }

    private func reload() {
        let latest = store.inventory().first { $0.id == fileID }
        file = latest
        guard let latest else {
            isEditing = false
            return
        }
        if !isEditing {
            expected = latest.annotation ?? .empty
            draft = expected
        } else if !latest.canEditAnnotation || latest.annotation == nil {
            message = "本機資訊目前無法讀取；未儲存的草稿仍保留。儲存時會由儲存區再次檢查。"
        }
    }

    private func date(_ date: Date?) -> String {
        guard let date else { return "無法取得" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
