import SwiftUI
import UniformTypeIdentifiers

private enum SideSignConfigMode: String, CaseIterable, Identifiable {
    case interactive = "Interactive"
    case rawJSON = "Raw JSON"
    var id: String { rawValue }
}

private struct SideSignConfigJSONDocument: FileDocument {
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
struct SideSignClientConfigurationView: View {
    @State private var draft = EiliSideSignClientConfiguration.empty
    @State private var raw = "{}"
    @State private var mode: SideSignConfigMode = .interactive
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var dirty = false
    @State private var importing = false
    @State private var exporting = false
    @State private var confirmReset = false
    @State private var document: SideSignConfigJSONDocument?
    @State private var notice: String?
    @State private var isError = false
    @State private var working = false

    private let headerKeys = ["svct", "Header: Version", "X-Apple-App-Info", "User-Agent",
                              "appIdKey", "User-Agent",
                              "clientId", "protocolVersion", "servicesProtocolVersion", "User-Agent"]

    private let fields: [(String, WritableKeyPath<EiliSideSignClientConfiguration, String>)] = [
        ("Service", \.grandSlam.service),
        ("Header Version", \.grandSlam.headerVersion),
        ("Auth App", \.grandSlam.authApp),
        ("User Agent", \.grandSlam.userAgent),
        ("App ID Key", \.appleAuth.appIDKey),
        ("User Agent", \.appleAuth.userAgent),
        ("Client ID", \.developerServices.clientID),
        ("Protocol Version", \.developerServices.protocolVersion),
        ("Services Protocol Version", \.developerServices.servicesProtocolVersion),
        ("User Agent", \.developerServices.userAgent)
    ]

    private var modeSelection: Binding<SideSignConfigMode> {
        Binding(get: { mode }, set: { changeMode(to: $0) })
    }

    var body: some View {
        Form {
            Section {
                Text("這些是 SideSign HTTP client／protocol headers，不是 VPN 或 Anisette 伺服器設定。欄位留白表示沿用 SideSign 預設值；儲存後於下一次操作生效，不會更動 Apple 帳戶 session、ADI 或 remoteMode。")
                    .font(.footnote)
                Picker("編輯方式", selection: modeSelection) {
                    ForEach(SideSignConfigMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sidesign-client-config-mode-picker")
                .disabled(!loaded || loadFailed || working)

                if dirty {
                    Label("尚有未儲存變更", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("sidesign-client-config-dirty")
                }
                if !loaded && !loadFailed {
                    Text("正在載入設定…").font(.caption).foregroundColor(.secondary)
                }
                if loadFailed {
                    Text("無法載入已儲存設定；儲存、匯入與匯出已停用。可重設以移除損壞設定。安全錯誤不會顯示欄位內容。")
                        .foregroundColor(.red)
                }
            }

            if mode == .interactive {
                group("GRANDSLAM AUTH (GSA)", keys: 0..<4)
                group("APPLE AUTH (IDMSA)", keys: 4..<6)
                group("DEVELOPER SERVICES", keys: 6..<10)
            } else {
                Section("RAW JSON") {
                    TextEditor(text: rawBinding)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 280)
                        .accessibilityIdentifier("sidesign-client-config-raw-json")
                        .disabled(!loaded || loadFailed || working)
                }
            }

            Section {
                Button("Save Overrides") { save() }
                    .accessibilityIdentifier("sidesign-client-config-save")
                    .disabled(!loaded || loadFailed || working || !dirty || !isDraftValid)
                Button("匯入 JSON") { importing = true }
                    .accessibilityIdentifier("sidesign-client-config-import")
                    .disabled(!loaded || loadFailed || working)
                Button("匯出目前草稿") { exportDraft() }
                    .accessibilityIdentifier("sidesign-client-config-export")
                    .disabled(!loaded || loadFailed || working || !isDraftValid)
                Button("重設覆寫", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("sidesign-client-config-reset")
                    .disabled(working)
                Text("匯出檔包含 HTTP headers，可能包含自訂 IDs；不包含 Apple 帳戶憑證。請妥善保管。")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundColor(isError ? .red : .secondary)
                }
            }
        }
        .disabled(working)
        .navigationTitle("SideSign Client Config")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false, onCompletion: importResult)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "sidesign-overrides", onCompletion: exportResult)
        .confirmationDialog("移除 SideSign 設定覆寫？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重設覆寫", role: .destructive) { reset() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只會移除本機 HTTP client 設定覆寫，不會更動 Apple 帳戶 session、ADI 或編輯模式。")
        }
        .task { await load() }
    }

    private var rawBinding: Binding<String> {
        Binding(get: { raw }, set: { raw = $0; dirty = true; notice = nil })
    }

    private func group(_ title: String, keys: Range<Int>) -> some View {
        Section(title) {
            ForEach(Array(keys), id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fields[index].0).font(.subheadline)
                        Spacer()
                        Text(headerKeys[index]).font(.caption2).foregroundColor(.secondary)
                    }
                    TextField(fields[index].0, text: fieldBinding(index))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("sidesign-client-config-field-\(index)")
                        .disabled(!loaded || loadFailed || working)
                }
            }
        }
    }

    private func fieldBinding(_ index: Int) -> Binding<String> {
        let key = fields[index].1
        return Binding(get: { draft[keyPath: key] }, set: { value in
            draft[keyPath: key] = value
            dirty = true
            notice = nil
        })
    }

    private var isDraftValid: Bool {
        if mode == .rawJSON {
            return (try? EiliSideSignClientConfiguration.decodeJSON(Data(raw.utf8))) != nil
        }
        return (try? draft.validated()) != nil
    }

    private func changeMode(to next: SideSignConfigMode) {
        guard loaded, !loadFailed, !working, next != mode else { return }
        if next == .interactive {
            do {
                let parsed = try EiliSideSignClientConfiguration.decodeJSON(Data(raw.utf8))
                draft = parsed
                dirty = true
                mode = next
                notice = nil
            } catch {
                showSafeError("Raw JSON 無效；修正後才可切回互動編輯，草稿已保留。")
            }
        } else {
            do {
                raw = String(data: try draft.encodedJSON(), encoding: .utf8) ?? "{}"
                mode = next
                notice = nil
            } catch {
                showSafeError("目前草稿無法轉換為 JSON；仍保留原編輯模式與草稿。")
            }
        }
    }

    private func load() async {
        guard !loaded, !working else { return }
        working = true
        do {
            let config = try await EiliSideSignClientConfigurationStore.shared.load()
            draft = config
            raw = String(data: (try? config.encodedJSON()) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
            loaded = true
            loadFailed = false
            dirty = false
            working = false
        } catch {
            loadFailed = true
            loaded = false
            working = false
            showSafeError("已儲存設定無法安全載入；可重設修復。")
        }
    }

    private func current() throws -> EiliSideSignClientConfiguration {
        try mode == .rawJSON
            ? EiliSideSignClientConfiguration.decodeJSON(Data(raw.utf8))
            : draft.validated()
    }

    private func save() {
        guard loaded, !loadFailed, !working else { return }
        let config: EiliSideSignClientConfiguration
        do { config = try current() }
        catch { showSafeError("草稿無效，無法儲存；請檢查欄位內容。"); return }
        working = true
        Task {
            do {
                try await EiliSideSignClientConfigurationStore.shared.save(config)
                draft = config
                raw = String(data: (try? config.encodedJSON()) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
                dirty = false
                working = false
                notice = "覆寫已儲存；下一次操作生效。"
                isError = false
            } catch {
                working = false
                showSafeError("儲存失敗；原有設定保留。")
            }
        }
    }

    private func reset() {
        guard !working else { return }
        working = true
        Task {
            do {
                try await EiliSideSignClientConfigurationStore.shared.reset()
                draft = .empty
                raw = String(data: (try? draft.encodedJSON()) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
                loaded = true
                loadFailed = false
                dirty = false
                working = false
                notice = "覆寫已重設。"
                isError = false
            } catch {
                working = false
                showSafeError("重設失敗；原有設定保留。")
            }
        }
    }

    private func exportDraft() {
        guard loaded, !loadFailed, !working else { return }
        do {
            document = SideSignConfigJSONDocument(data: try current().encodedJSON())
            exporting = true
        } catch {
            showSafeError("目前草稿無效，無法匯出。")
        }
    }

    private func importResult(_ result: Result<[URL], Error>) {
        guard loaded, !loadFailed, !working else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 65_536 else {
                showSafeError("檔案必須是非符號連結的 regular JSON，且不超過 64 KiB。")
                return
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else {
                showSafeError("JSON 檔案超過 64 KiB。")
                return
            }
            let config = try EiliSideSignClientConfiguration.decodeJSON(data)
            draft = config
            raw = String(data: try config.encodedJSON(), encoding: .utf8) ?? "{}"
            dirty = true
            notice = "JSON 已載入草稿；按 Save Overrides 才會儲存。"
            isError = false
        } catch {
            showSafeError("匯入失敗，請檢查 JSON 格式與欄位。")
        }
    }

    private func exportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            notice = "JSON 草稿已匯出。"
            isError = false
        case .failure:
            showSafeError("匯出失敗。")
        }
    }

    private func showSafeError(_ text: String) {
        notice = text
        isError = true
    }
}
