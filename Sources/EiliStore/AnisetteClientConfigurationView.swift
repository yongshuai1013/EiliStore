import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum AnisetteConfigEditorMode: String, CaseIterable, Identifiable {
    case interactive = "Interactive"
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

    @State private var isFetchingRemote = false
    @State private var isRemoteSyncExpanded = false
    @State private var remoteServerHeaders: [String: String] = [:]
    @State private var remoteServerHeadersJSON = "{}"
    @State private var remoteServerHost: String?
    @State private var remoteSyncNotice: String?
    @State private var remoteSyncNoticeIsError = false
    @State private var isCopiedRemoteHeaders = false

    private var modeSelection: Binding<AnisetteConfigEditorMode> {
        Binding(get: { mode }, set: { changeMode(to: $0) })
    }


    private var remoteServerDescription: String {
        let server = AnisetteServerManager.shared.selectedServer
        return "Server: \(remoteServerHost ?? server.nsURL?.host ?? server.name)"
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
                Section("PRIMARY CLIENT HEADERS") {
                    configField("Client Info", headerKey: "X-Mme-Client-Info", key: \.clientInfo, id: "client-config-client-info")
                    configField("User Agent", headerKey: "User-Agent", key: \.userAgent, id: "client-config-user-agent")
                }
                Section("DEVICE & IDENTITY") {
                    configField("Custom Device ID", headerKey: "X-Mme-Device-Id", key: \.customDeviceID, id: "client-config-device-id", placeholder: "System Generated Device UUID")
                    configField("Custom Local User ID", headerKey: "X-Apple-I-MD-LU", key: \.customLocalUserID, id: "client-config-local-user-id", placeholder: "0")
                    configField("Custom Serial Number", headerKey: "X-Apple-I-SRL-NO", key: \.customSerialNumber, id: "client-config-serial-number")
                    configField("Custom Routing Info", headerKey: "X-Apple-I-MD-RINFO", key: \.customRoutingInfo, id: "client-config-routing-info")
                }
                Section("ENVIRONMENT & LOCALIZATION") {
                    configField("Custom Locale", headerKey: "X-Apple-Locale", key: \.customLocale, id: "client-config-locale")
                    configField("Custom Time Zone", headerKey: "X-Apple-I-TimeZone", key: \.customTimeZone, id: "client-config-time-zone")
                    configField("Custom Xcode Version", headerKey: "X-Xcode-Version", key: \.customXcodeVersion, id: "client-config-xcode-version")
                    Text("Xcode 版本留白時，新登入使用 27.0 (27A242)，既有會話沿用其保存版本。其他空白欄位沿用 provider/default。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("DYNAMIC CRYPTOGRAPHIC TOKENS") {
                    tokenInfoRow("One-Time Password (OTP)", headerKey: "X-Apple-I-MD", note: "由 Anisette 於每次請求時產生，不儲存於 Client Configuration。")
                    tokenInfoRow("Machine ID", headerKey: "X-Apple-I-MD-M", note: "由 Anisette 於每次請求時產生，不儲存於 Client Configuration。")
                    tokenInfoRow("Client Time", headerKey: "X-Apple-I-Client-Time", note: "每次請求時取自裝置目前時間，不儲存於 Client Configuration。")
                }
            } else {
                Section("RAW JSON") {
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

            if EiliAnisetteMode.selected == .remote {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.purple)
                                .frame(width: 40, height: 40)
                                .background(Color.purple.opacity(0.12))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remote Server Sync")
                                    .font(.headline)
                                Text("同步所選伺服器的 Client Info")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            // SideStore's Fetch is a capsule pill; here it uses
                            // EiliStore's own accent theme instead of purple.
                            Button(action: fetchRemoteServerConfiguration) {
                                if isFetchingRemote {
                                    ProgressView()
                                        .scaleEffect(0.85)
                                        .frame(minWidth: 44, minHeight: 30)
                                } else {
                                    Label("刷新", systemImage: "arrow.clockwise")
                                        .font(.footnote.weight(.semibold))
                                        .frame(minHeight: 30)
                                }
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .foregroundColor(.accentColor)
                            .tint(.accentColor)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .disabled(!isLoaded || isBusy)
                            .accessibilityIdentifier("anisette-remote-sync-fetch")

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isRemoteSyncExpanded.toggle()
                                }
                            } label: {
                                Image(systemName: isRemoteSyncExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityLabel(isRemoteSyncExpanded ? "收合遠端同步" : "展開遠端同步")
                            .accessibilityIdentifier("anisette-remote-sync-toggle")
                        }

                        if isRemoteSyncExpanded {
                            Divider()

                            HStack(spacing: 8) {
                                Text(remoteServerDescription)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: 4)
                                Button {
                                    UIPasteboard.general.string = remoteServerHeadersJSON
                                    withAnimation(.easeInOut(duration: 0.2)) { isCopiedRemoteHeaders = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation(.easeInOut(duration: 0.2)) { isCopiedRemoteHeaders = false }
                                    }
                                } label: {
                                    Label(isCopiedRemoteHeaders ? "已複製" : "複製", systemImage: isCopiedRemoteHeaders ? "checkmark" : "doc.on.doc")
                                        .font(.footnote.weight(.semibold))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(.purple)
                                .accessibilityIdentifier("anisette-remote-sync-copy")
                            }

                            ScrollView(.horizontal, showsIndicators: true) {
                                Text(remoteServerHeadersJSON)
                                    .font(.system(.footnote, design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: true)
                                    .frame(maxHeight: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 144, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.purple.opacity(0.12), lineWidth: 1))
                            .accessibilityIdentifier("anisette-remote-sync-headers")

                            if let remoteSyncNotice {
                                Label(remoteSyncNotice, systemImage: remoteSyncNoticeIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                    .font(.footnote.weight(.medium))
                                    .foregroundColor(remoteSyncNoticeIsError ? .red : .green)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background((remoteSyncNoticeIsError ? Color.red : Color.green).opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityIdentifier("anisette-remote-sync-notice")
                            }

                            Button(action: saveFetchedServerHeadersAsOverrides) {
                                Label("儲存為覆寫", systemImage: "square.and.arrow.down.on.square")
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(BorderedProminentButtonStyle())
                            .tint(.purple)
                            .disabled(!isLoaded || isBusy || remoteServerHeaders.isEmpty)
                            .accessibilityIdentifier("anisette-remote-sync-save-overrides")
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.purple.opacity(0.14), lineWidth: 1))
                    .accessibilityIdentifier("anisette-remote-server-sync-card")
                    .animation(.easeInOut(duration: 0.2), value: isFetchingRemote)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("REMOTE SERVER SYNC")
                }
                .textCase(nil)
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

    private func configField(_ title: String, headerKey: String, key: WritableKeyPath<EiliAnisetteClientConfiguration, String>, id: String, placeholder: String = "空白＝沿用預設") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer()
                Text(headerKey).font(.caption2).foregroundColor(.secondary)
            }
            TextField(placeholder, text: Binding(
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

    private func tokenInfoRow(_ title: String, headerKey: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline)
                Spacer()
                Text(headerKey).font(.caption2).foregroundColor(.secondary)
            }
            Text(note).font(.caption).foregroundColor(.secondary)
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

    private func fetchRemoteServerConfiguration() {
        guard isLoaded, !isBusy else { return }
        isBusy = true
        isFetchingRemote = true
        remoteSyncNotice = nil
        message = nil
        Task {
            defer {
                isFetchingRemote = false
                isBusy = false
            }
            do {
                let server = AnisetteServerManager.shared.selectedServer
                guard let serverURL = server.nsURL else {
                    throw EiliAnisetteRemoteServerSync.SyncError.unsupportedServerURL
                }
                let headers = try await EiliAnisetteRemoteServerSync.fetchHeaders(from: serverURL)
                let data = try JSONSerialization.data(withJSONObject: headers, options: [.prettyPrinted, .sortedKeys])
                guard let text = String(data: data, encoding: .utf8) else {
                    throw EiliAnisetteRemoteServerSync.SyncError.invalidResponse
                }
                remoteServerHeaders = headers
                remoteServerHeadersJSON = text
                remoteServerHost = serverURL.host
                remoteSyncNotice = "已成功取得伺服器設定。"
                remoteSyncNoticeIsError = false
                withAnimation(.easeInOut(duration: 0.2)) { isRemoteSyncExpanded = true }
            } catch {
                remoteSyncNotice = "刷新失敗：\(error.localizedDescription)"
                remoteSyncNoticeIsError = true
            }
        }
    }

    private func saveFetchedServerHeadersAsOverrides() {
        guard isLoaded, !isBusy, !remoteServerHeaders.isEmpty else { return }
        do {
            let current: EiliAnisetteClientConfiguration
            if mode == .rawJSON {
                current = try EiliAnisetteClientConfiguration.decodeJSON(Data(rawJSON.utf8))
            } else {
                current = try draft.validated()
            }
            let updated = try current.mergingServerHeaders(remoteServerHeaders)
            guard updated != current else {
                remoteSyncNotice = "回應中沒有可套用的 Anisette 設定欄位。"
                remoteSyncNoticeIsError = true
                return
            }
            isBusy = true
            Task {
                do {
                    try await EiliAnisetteClientConfigurationStore.shared.save(updated)
                    draft = updated
                    rawJSON = Self.jsonText(updated) ?? rawJSON
                    isDirty = false
                    remoteSyncNotice = "伺服器設定已儲存為覆寫。"
                    remoteSyncNoticeIsError = false
                    isBusy = false
                } catch {
                    isBusy = false
                    remoteSyncNotice = "無法儲存伺服器設定覆寫。請稍後重試。"
                    remoteSyncNoticeIsError = true
                }
            }
        } catch {
            remoteSyncNotice = "伺服器設定無法套用：\(error.localizedDescription)"
            remoteSyncNoticeIsError = true
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
