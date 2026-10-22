import SwiftUI
import UniformTypeIdentifiers

private enum AnisetteConfigEditorMode: String, CaseIterable, Identifiable {
    case interactive = "互動編輯"
    case rawJSON = "Raw JSON"
    var id: String { rawValue }
}

private struct AnisetteJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
struct AnisetteClientConfigurationView: View {
    @State private var draft = EiliAnisetteClientConfiguration.empty
    @State private var rawJSON = "{}"
    @State private var mode: AnisetteConfigEditorMode = .interactive
    @State private var isLoaded = false
    @State private var isDirty = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var showResetConfirmation = false
    @State private var exportDocument: AnisetteJSONDocument?
    @State private var message: String?
    @State private var isError = false
    @State private var isBusy = false

    private var modeSelection: Binding<AnisetteConfigEditorMode> {
        Binding(get: { mode }, set: { changeMode(to: $0) })
    }

    private var rawBinding: Binding<String> {
        Binding(get: { rawJSON }, set: { value in
            rawJSON = value
            isDirty = true
            message = nil
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("編輯方式", selection: modeSelection) {
                    ForEach(AnisetteConfigEditorMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .accessibilityIdentifier("client-config-mode-picker")
                .disabled(!isLoaded || isBusy)

                if isDirty {
                    Label("尚有未儲存變更", systemImage: "circle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
                if !isLoaded {
                    Text("正在載入設定…").font(.caption).foregroundColor(.secondary)
                }
            }

            if mode == .interactive {
                Section("用戶自定義") {
                    configField("Client Info", key: \.clientInfo, id: "client-config-client-info")
                    configField("User Agent", key: \.userAgent, id: "client-config-user-agent")
                    configField("Custom Device ID", key: \.customDeviceID, id: "client-config-device-id")
                    configField("Custom Local User ID", key: \.customLocalUserID, id: "client-config-local-user-id")
                    configField("Custom Serial Number", key: \.customSerialNumber, id: "client-config-serial-number")
                    configField("Custom Routing Info", key: \.customRoutingInfo, id: "client-config-routing-info")
                    configField("Custom Locale", key: \.customLocale, id: "client-config-locale")
                    configField("Custom Time Zone", key: \.customTimeZone, id: "client-config-time-zone")
                    configField("Custom Xcode Version", key: \.customXcodeVersion, id: "client-config-xcode-version")
                    Text("Xcode 版本留白時，新登入使用 27.0 (27A242)，既有會話沿用其保存版本。其他空白欄位沿用 provider/default。")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Section("JSON") {
                    TextEditor(text: rawBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
                        .accessibilityIdentifier("client-config-raw-json")
                        .disabled(!isLoaded || isBusy)
                }
            }

            Section {
                Button { save() } label: {
                    if isBusy { ProgressView() } else { Text("儲存覆寫") }
                }
                .accessibilityIdentifier("client-config-save")
                .disabled(!isLoaded || isBusy || !isDirty)
                Button("匯入 JSON…") { isImporting = true }
                    .accessibilityIdentifier("client-config-json-import")
                    .disabled(!isLoaded || isBusy)
                Button("匯出目前草稿 JSON…") { prepareExport() }
                    .accessibilityIdentifier("client-config-json-export")
                    .disabled(!isLoaded || isBusy)
                Button("重設覆寫…", role: .destructive) { showResetConfirmation = true }
                    .accessibilityIdentifier("client-config-reset")
                    .disabled(isBusy)
                Text("匯出的檔案包含自訂設備識別資訊；不包含 Apple 密碼、OTP 或 ADI。請妥善保管。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("注意事項") {
                Text("九項設定對遠端與 OnDevice 模式皆有效。儲存後於下一次登入或 Anisette 請求生效；空白代表沿用 provider/default。")
                Text("身份欄位不會更改 provisioningUUID 或 ADI 資料。自訂值可能導致 Apple 拒絕請求，請謹慎修改。")
            }
            .font(.footnote).foregroundColor(.secondary)

            if let message {
                Section { Text(message).font(.footnote).foregroundColor(isError ? .red : .secondary) }
            }
        }
        .disabled(isBusy)
        .navigationTitle("Client Config")
        .onAppear { load() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: importResult)
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: "anisette-client-config", onCompletion: exportResult)
        .confirmationDialog("重設用戶自定義？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("重設覆寫", role: .destructive) { reset() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只會刪除用戶自定義設定並清空此頁草稿，不會更改 session 或 ADI。")
        }
    }

    private func configField(_ title: String, key: WritableKeyPath<EiliAnisetteClientConfiguration, String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline)
            TextField("空白＝沿用預設", text: Binding(
                get: { draft[keyPath: key] },
                set: { value in
                    draft[keyPath: key] = value
                    isDirty = true
                    message = nil
                }
            ))
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .accessibilityIdentifier(id)
            .disabled(!isLoaded || isBusy)
        }
    }

    private func load() {
        guard !isLoaded, !isBusy else { return }
        isBusy = true
        Task {
            do {
                let value = try await EiliAnisetteClientConfigurationStore.shared.load()
                draft = value
                rawJSON = Self.jsonText(value) ?? "{}"
                isLoaded = true
                isDirty = false
                isBusy = false
            } catch {
                isLoaded = false
                isBusy = false
                showError("無法載入設定。為避免覆寫未知資料，儲存與匯入已停用；可嘗試重設。")
            }
        }
    }

    private func changeMode(to newMode: AnisetteConfigEditorMode) {
        guard isLoaded, !isBusy, newMode != mode else { return }
        if newMode == .interactive {
            do {
                let value = try EiliAnisetteClientConfiguration.decodeJSON(Data(rawJSON.utf8))
                draft = value
                mode = newMode
                isDirty = true
                message = nil
            } catch {
                showError("Raw JSON 無效，請修正後再切換至互動編輯；草稿已保留。")
            }
        } else {
            guard let text = Self.jsonText(draft) else {
                showError("目前草稿無法轉換為 JSON；仍保留原編輯模式與草稿。")
                return
            }
            rawJSON = text
            mode = newMode
            message = nil
        }
    }

    private func save() {
        guard isLoaded, !isBusy else { return }
        let value: EiliAnisetteClientConfiguration
        if mode == .rawJSON {
            do { value = try EiliAnisetteClientConfiguration.decodeJSON(Data(rawJSON.utf8)) }
            catch { showError("JSON 無效，請修正後再儲存。"); return }
        } else { value = draft }
        do { _ = try value.validated() }
        catch { showError("設定內容無效，請檢查欄位後再儲存。"); return }
        isBusy = true
        Task {
            do {
                try await EiliAnisetteClientConfigurationStore.shared.save(value)
                draft = value
                rawJSON = Self.jsonText(value) ?? rawJSON
                isDirty = false
                isBusy = false
                showSuccess("覆寫設定已儲存；下次登入或 Anisette 請求生效。")
            } catch {
                isBusy = false
                showError("無法儲存設定。請稍後重試。")
            }
        }
    }

    private func reset() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await EiliAnisetteClientConfigurationStore.shared.reset()
                draft = .empty
                rawJSON = "{}"
                isDirty = false
                isLoaded = true
                isBusy = false
                showSuccess("覆寫已重設；session 與 ADI 未更動。")
            } catch {
                isBusy = false
                showError("無法重設設定。請稍後重試。")
            }
        }
    }

    private func prepareExport() {
        guard isLoaded, !isBusy else { return }
        let value: EiliAnisetteClientConfiguration
        if mode == .rawJSON {
            do { value = try EiliAnisetteClientConfiguration.decodeJSON(Data(rawJSON.utf8)) }
            catch { showError("JSON 無效，無法匯出。"); return }
        } else { value = draft }
        do { _ = try value.validated() }
        catch { showError("草稿內容無效，無法匯出。"); return }
        guard let data = Self.jsonData(value) else { showError("無法產生 JSON 匯出檔案。"); return }
        exportDocument = AnisetteJSONDocument(data: data)
        isExporting = true
        message = nil
    }

    private func importResult(_ result: Result<[URL], Error>) {
        guard isLoaded, !isBusy else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 65_536 else {
                showError("檔案必須是非符號連結的 regular JSON，且不超過 64 KiB。")
                return
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else {
                showError("JSON 檔案超過 64 KiB。")
                return
            }
            let imported = try EiliAnisetteClientConfiguration.decodeJSON(data)
            draft = imported
            rawJSON = Self.jsonText(imported) ?? "{}"
            isDirty = true
            message = "JSON 已匯入草稿，尚未儲存；請檢查內容後明確按下儲存覆寫。"
            isError = false
        } catch {
            showError("無法匯入 JSON。請確認檔案格式與內容。")
        }
    }

    private func exportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success: showSuccess("JSON 草稿已匯出。")
        case .failure: showError("無法匯出 JSON 檔案。")
        }
    }

    private static func jsonData(_ value: EiliAnisetteClientConfiguration) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    private static func jsonText(_ value: EiliAnisetteClientConfiguration) -> String? {
        guard let data = jsonData(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func showError(_ text: String) { message = text; isError = true }
    private func showSuccess(_ text: String) { message = text; isError = false }
}
