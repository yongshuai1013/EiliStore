import SwiftUI

// SideStore 精確顏色
func expiryColor(days: Int) -> Color {
        switch days {
        case 2...3: return Color(red: 1.000, green: 0.584, blue: 0.000) // RefreshOrange
        case 4...5: return Color(red: 1.000, green: 0.800, blue: 0.000) // RefreshYellow
        case 6...: return Color(red: 0.204, green: 0.780, blue: 0.349) // RefreshGreen
        default: return Color(red: 1.000, green: 0.231, blue: 0.188) // RefreshRed
        }
}

@main
struct EiliStoreApp: App {
    // Keep failure closed for the entire UI lifetime; factories also call the
    // same gate before FFI use and will observe the cached failure.
    private let rustLoggingConfigured: Bool

    init() {
        do {
            try RustLoggingPrivacy.ensureConfigured()
            rustLoggingConfigured = true
        } catch {
            rustLoggingConfigured = false
        }
    }

    var body: some Scene {
        WindowGroup {
            if rustLoggingConfigured {
                MainTabView()
            } else {
                Text("無法安全初始化裝置連線，已停止啟用。")
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            MyAppsView()
                .tabItem {
                    Label("主頁", systemImage: "house.fill")
                }
            
            SourcesView()
                .tabItem {
                    Label("軟體源", systemImage: "link")
                }
            
            SignInstallView()
                .tabItem {
                    Label("簽名", systemImage: "signature")
                }
            
            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape.fill")
                }
        }
        .accentColor(.teal)
    }
}

// MARK: - 主頁（My Apps 風格，不顯示 Apple ID）
private struct PendingExternalIconImport {
    let name: String
    let bundleId: String
    let iconData: Data
}

struct MyAppsView: View {
    @StateObject private var manager = AppManager.shared
    @State private var showAppIDsSheet = false
    @State private var activeHomeSheet: HomeSheet?
    @State private var pendingIconImport: PendingExternalIconImport?
    @State private var isImportingExternalIcon = false
    @State private var showIconImportResult = false
    @State private var iconImportMessage = ""
    @State private var iconChangeTargetBundleId: String?
    @State private var showRefreshToast = false
    @State private var refreshToastGeneration = UUID()

    private enum HomeSheet: String, Identifiable {
        case appIDSelection
        case importIcon
        case changeIcon
        case iconTargetSelection

        var id: String { rawValue }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 更新橫幅
                    Text(manager.hasUpdates ? "有 \(manager.appsNeedingRefresh.count) 個 App 需要刷新" : "沒有可用更新")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal.opacity(0.12))
                        .cornerRadius(16)
                    
                    // 已安裝標題行
                    HStack {
                        Text("已安裝")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button {
                            Task {
                                await manager.refreshAll(includeExternal: false)
                            }
                        } label: {
                            if manager.isRefreshing {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("全部刷新")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.teal)
                        .disabled(manager.isRefreshing)
                    }
                    
                    // App 列表
                    if manager.installedApps.isEmpty {
                        Text("還沒有安裝 App")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        ForEach(manager.displayApps) { app in
                            AppRowView(app: app, manager: manager) {
                                iconChangeTargetBundleId = app.bundleId
                                activeHomeSheet = .changeIcon
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let app = manager.installedApps[index]
                                // 刪除保存的 IPA 文件
                                if let ipaPath = app.ipaPath {
                                    try? FileManager.default.removeItem(atPath: ipaPath)
                                    AppLogger.shared.log("已刪除 IPA: \(ipaPath)")
                                }
                                manager.removeApp(bundleId: app.bundleId)
                            }
                        }
                    }
                    
                    // 外部 App（包含只匯入圖示的項目）— 跟上面列表同樣的卡片樣式
                    if !manager.externalDisplayBundleIds.isEmpty {
                        // 標題行
                        HStack {
                            Text("外部 App")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            if !manager.externalBundleIds.isEmpty {
                                Button {
                                    Task {
                                        await manager.refreshExternalOnly()
                                    }
                                } label: {
                                    if manager.isRefreshingExternal || manager.isRefreshing {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Text("全部刷新")
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.teal)
                                .disabled(manager.isRefreshingExternal || manager.isRefreshing)
                            }
                        }
                        ForEach(manager.externalDisplayBundleIds, id: \.self) { bid in
                            HStack(spacing: 12) {
                                // 匯入的圖示優先，其次嘗試從已安裝 App 取得圖示。
                                if let iconPath = manager.externalIconPath(for: bid),
                                   let uiImage = UIImage(contentsOfFile: iconPath) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 52, height: 52)
                                        .cornerRadius(12)
                                } else if let uiImage = AppIconHelper.shared.icon(for: bid) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 52, height: 52)
                                        .cornerRadius(12)
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.teal.opacity(0.18))
                                        .frame(width: 52, height: 52)
                                        .overlay(
                                            Image(systemName: "app.fill")
                                                .foregroundColor(.teal)
                                        )
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(manager.externalNames[bid] ?? bid)
                                        .font(.headline)
                                        .bold()
                                        .lineLimit(1)
                                    Text(bid)
                                        .font(.caption)
                                        .foregroundColor(.teal.opacity(0.6))
                                        .lineLimit(1)
                                    Text("外部")
                                        .font(.caption)
                                        .foregroundColor(.teal.opacity(0.75))
                                }
                                Spacer()
                                // 到期天數（跟已安裝一樣）
                                if manager.externalBundleIds.contains(bid),
                                   let exp = manager.externalExpiry[bid] {
                                    let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
                                    Button {
                                        Task { await manager.refreshExternalApp(bundleId: bid) }
                                    } label: {
                                        ZStack {
                                            let isRefreshing = manager.currentlyRefreshingBundleId == bid
                                            let bgColor = expiryColor(days: days)
                                            RoundedRectangle(cornerRadius: 17.5)
                                                .fill(isRefreshing ? bgColor.opacity(0.15) : bgColor)
                                            if isRefreshing {
                                                GeometryReader { geo in
                                                    RoundedRectangle(cornerRadius: 17.5)
                                                        .fill(bgColor)
                                                        .frame(width: max(0, geo.size.width * manager.refreshFraction))
                                                }
                                                .transition(.opacity)
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                                    .scaleEffect(0.8)
                                                    .transition(.opacity)
                                            }
                                            Text("\(days) 天")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(isRefreshing ? .clear : .white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                        }
                                        .frame(width: 77, height: 35)
                                        .animation(.linear(duration: 0.25), value: manager.refreshFraction)
                                        .animation(.easeInOut(duration: 0.2), value: manager.currentlyRefreshingBundleId)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .disabled(manager.isRefreshing || manager.isRefreshingExternal)
                                    .accessibilityLabel("刷新 \(manager.externalNames[bid] ?? bid)")
                                }
                            }
                            .padding()
                            .background(Color.teal.opacity(0.08))
                            .cornerRadius(20)
                            .appCardContextMenu(
                                info: AppCardInfo(
                                    name: manager.externalNames[bid] ?? bid,
                                    bundleId: bid,
                                    team: nil,
                                    expiresDate: manager.externalExpiry[bid],
                                    isExternal: true,
                                    hasSavedIPA: nil,
                                    hasImportedIcon: manager.externalIconPath(for: bid) != nil
                                ),
                                canRefresh: manager.externalBundleIds.contains {
                                    $0.caseInsensitiveCompare(bid) == .orderedSame
                                },
                                isBusy: manager.isRefreshing || manager.isRefreshingExternal,
                                onRefresh: {
                                    guard let refreshBundleId = manager.externalBundleIds.first(where: {
                                        $0.caseInsensitiveCompare(bid) == .orderedSame
                                    }) else { return }
                                    Task { await manager.refreshExternalApp(bundleId: refreshBundleId) }
                                },
                                onChangeIcon: {
                                    iconChangeTargetBundleId = bid
                                    activeHomeSheet = .changeIcon
                                }
                            )
                        }
                    }
                    
                    // App ID 剩餘
                    VStack(spacing: 4) {
                        Text("\(manager.appIDsRemaining) 個 App ID 剩餘")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("查看 App IDs") {
                            showAppIDsSheet = true
                        }
                        .font(.subheadline)
                        .foregroundColor(.teal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .sheet(isPresented: $showAppIDsSheet) {
                        AppIDsSheetView()
                    }
                }
                .padding()
            }
            .navigationTitle("My Apps")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                KeepAlive.shared.start()
                // 自動啟動常駐心跳（如果有配對檔）
                Task {
                    if let pairingURL = findPairingFileURL(),
                       await VPNConnectionChecker.shared.checkConnection() {
                        let host = VPNConnectionChecker.shared.effectiveGatewayHost
                        try? await HeartbeatManager.shared.start(pairingFileURL: pairingURL, host: host)
                    }
                }
                manager.refreshAppIDsRemaining()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            activeHomeSheet = .appIDSelection
                        } label: {
                            Label("選擇需要刷新的 App ID", systemImage: "checkmark.circle")
                        }
                        Button {
                            activeHomeSheet = .importIcon
                        } label: {
                            Label("從 IPA 匯入圖示", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        if isImportingExternalIcon {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "plus")
                                .foregroundColor(.teal)
                        }
                    }
                    .disabled(isImportingExternalIcon)
                }
            }
            .sheet(item: $activeHomeSheet) { sheet in
                switch sheet {
                case .appIDSelection:
                    AppIDSelectionView()
                case .importIcon:
                    DocumentPicker(
                        onPick: { url in
                            activeHomeSheet = nil
                            importExternalIcon(from: url)
                        },
                        onCancel: {
                            activeHomeSheet = nil
                        }
                    )
                case .changeIcon:
                    if let targetBundleId = iconChangeTargetBundleId {
                        DocumentPicker(
                            onPick: { url in
                                activeHomeSheet = nil
                                iconChangeTargetBundleId = nil
                                importExternalIcon(from: url, targetBundleId: targetBundleId)
                            },
                            onCancel: {
                                activeHomeSheet = nil
                                iconChangeTargetBundleId = nil
                            }
                        )
                    } else {
                        EmptyView()
                    }
                case .iconTargetSelection:
                    if let pending = pendingIconImport {
                        ExternalIconTargetPicker(
                            sourceName: pending.name,
                            sourceBundleId: pending.bundleId,
                            targetBundleIds: manager.externalIconTargetBundleIds.filter {
                                $0.caseInsensitiveCompare(pending.bundleId) != .orderedSame
                            },
                            externalNames: manager.externalNames,
                            onSelect: { targetBundleId in
                                activeHomeSheet = nil
                                pendingIconImport = nil
                                completeExternalIconAssociation(pending, targetBundleId: targetBundleId)
                            },
                            onCancel: {
                                activeHomeSheet = nil
                                pendingIconImport = nil
                            }
                        )
                    } else {
                        EmptyView()
                    }
                }
            }
            .alert("IPA 圖示匯入", isPresented: $showIconImportResult) {
                Button("好", role: .cancel) {}
            } message: {
                Text(iconImportMessage)
            }
            .task {
                // App 啟動時檢查是否需要自動刷新
                await manager.checkAndAutoRefresh()
            }
            .overlay(alignment: .bottom) {
                if showRefreshToast {
                    HStack(spacing: 10) {
                        Image(systemName: manager.isRefreshError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        Text(manager.refreshProgress)
                            .lineLimit(2)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(manager.isRefreshError ? Color.red : Color.teal))
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                }
            }
            .onChange(of: manager.isRefreshing) { _ in self.showRefreshToastIfFinished() }
            .onChange(of: manager.isRefreshingExternal) { _ in self.showRefreshToastIfFinished() }
            .onChange(of: manager.refreshProgress) { _ in self.showRefreshToastIfFinished() }
        }
    }

    private func importExternalIcon(from ipaURL: URL, targetBundleId: String? = nil) {
        guard !isImportingExternalIcon else { return }
        isImportingExternalIcon = true

        Task {
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let info = try IPAParser.parse(ipaURL: ipaURL)
                    return (name: info.name, bundleId: info.bundleId, iconData: info.iconData)
                }.value

                guard let iconData = parsed.iconData else {
                    throw ExternalIconImportError.missingIcon
                }
                guard !parsed.bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      parsed.bundleId != "unknown" else {
                    throw ExternalIconImportError.invalidBundleIdentifier
                }

                if let targetBundleId {
                    let installedTarget = manager.installedApps.first {
                        $0.bundleId.caseInsensitiveCompare(targetBundleId) == .orderedSame
                    }
                    let externalTarget = manager.externalDisplayBundleIds.first {
                        $0.caseInsensitiveCompare(targetBundleId) == .orderedSame
                    }
                    guard installedTarget != nil || externalTarget != nil else {
                        throw ExternalIconImportError.invalidIconTarget
                    }
                    try manager.saveExternalIcon(bundleId: targetBundleId, iconData: iconData)
                    let targetName = installedTarget?.name
                        ?? manager.externalNames.first(where: { $0.key.caseInsensitiveCompare(targetBundleId) == .orderedSame })?.value
                        ?? targetBundleId
                    iconImportMessage = "已將「\(parsed.name)」的圖示套用到「\(targetName)」卡片。這只變更 EiliStore 清單顯示，不會安裝或簽名 IPA，也不會更改裝置主畫面圖示。"
                    showIconImportResult = true
                } else if let matchedBundleId = manager.existingIconTargetBundleId(for: parsed.bundleId) {
                    try manager.saveExternalIcon(bundleId: matchedBundleId, iconData: iconData)
                    iconImportMessage = "已匯入「\(parsed.name)」的圖示，並自動配對至既有項目 \(matchedBundleId)。未安裝或簽名 IPA。"
                    showIconImportResult = true
                } else {
                    let targets = manager.externalIconTargetBundleIds.filter {
                        $0.caseInsensitiveCompare(parsed.bundleId) != .orderedSame
                    }
                    guard !targets.isEmpty else {
                        throw ExternalIconImportError.noExistingExternalTargets
                    }
                    pendingIconImport = PendingExternalIconImport(
                        name: parsed.name,
                        bundleId: parsed.bundleId,
                        iconData: iconData
                    )
                    activeHomeSheet = .iconTargetSelection
                }
            } catch {
                iconImportMessage = "匯入失敗：\(error.localizedDescription)"
                showIconImportResult = true
            }

            isImportingExternalIcon = false
        }
    }

    private func completeExternalIconAssociation(_ pending: PendingExternalIconImport, targetBundleId: String) {
        do {
            try manager.saveExternalIcon(
                bundleId: targetBundleId,
                iconData: pending.iconData,
                removingSourceBundleId: pending.bundleId
            )
            let targetName = manager.externalNames[targetBundleId] ?? targetBundleId
            iconImportMessage = "已將「\(pending.name)」的圖示關聯至既有外部 App「\(targetName)」（\(targetBundleId)）。來源 Bundle ID 不會新增為另一列；Apple App ID、刷新清單與名稱均未更改。"
        } catch {
            iconImportMessage = "圖示配對失敗：\(error.localizedDescription)"
        }
        showIconImportResult = true
    }

    private enum ExternalIconImportError: LocalizedError {
        case missingIcon
        case invalidBundleIdentifier
        case invalidIconTarget
        case noExistingExternalTargets

        var errorDescription: String? {
            switch self {
            case .missingIcon:
                return "IPA 中找不到可匯入的 App 圖示"
            case .invalidBundleIdentifier:
                return "IPA 中找不到有效的 Bundle ID"
            case .invalidIconTarget:
                return "目標 App 已不存在，無法變更卡片圖示"
            case .noExistingExternalTargets:
                return "目前沒有可配對的既有外部 App；圖標未匯入，也未更動刷新清單。"
            }
        }
    }

    private func showRefreshToastIfFinished() {
        guard !manager.isRefreshing, !manager.isRefreshingExternal,
              !manager.refreshProgress.isEmpty else { return }

        let generation = UUID()
        refreshToastGeneration = generation
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showRefreshToast = true
        }

        let duration: TimeInterval = manager.isRefreshError ? 8 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard self.refreshToastGeneration == generation,
                  !self.manager.isRefreshing, !self.manager.isRefreshingExternal else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.showRefreshToast = false
            }
        }
    }

    private func findPairingFileURL() -> URL? {
        PairingFileStore.shared.selectedPairingFileURL()
    }

}

private struct ExternalIconTargetPicker: View {
    let sourceName: String
    let sourceBundleId: String
    let targetBundleIds: [String]
    let externalNames: [String: String]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("IPA 來源 Bundle ID：\(sourceBundleId)。只會將圖標關聯至所選既有項目，不會新增來源列或更改刷新清單與名稱。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if targetBundleIds.isEmpty {
                        Text("目前沒有可選擇的既有外部 App。")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(targetBundleIds, id: \.self) { bundleId in
                            Button {
                                onSelect(bundleId)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "app.fill")
                                        .foregroundColor(.teal)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(externalNames[bundleId] ?? bundleId)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(bundleId)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                } header: {
                    Text("IPA：\(sourceName)")
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("選擇圖標目標")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
        }
    }
}

struct AppRowView: View {
    let app: InstalledApp
    @ObservedObject var manager: AppManager
    let onChangeIcon: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // App 圖標（安裝時從 IPA 解出；EiliStore 自身從 bundle 讀）
            if let iconPath = manager.externalIconPath(for: app.bundleId),
               let uiImage = UIImage(contentsOfFile: iconPath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .cornerRadius(12)
            } else if let iconPath = app.iconPath,
                      let uiImage = UIImage(contentsOfFile: iconPath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .cornerRadius(12)
            } else if app.bundleId == Bundle.main.bundleIdentifier,
                      let uiImage = UIImage(named: "EiliStoreIcon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.teal.opacity(0.18))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "app.fill")
                            .foregroundColor(.teal)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                    .bold()
                Text(app.bundleId)
                    .font(.caption)
                    .foregroundColor(.teal.opacity(0.75))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("剩餘")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                // 對照 SideStore 的 PillButton：點有效期膠囊即可刷新此 App。
                Button {
                    Task {
                        await manager.refreshApp(app)
                    }
                } label: {
                    ZStack {
                        let isRefreshing = manager.currentlyRefreshingBundleId == app.bundleId
                        let bgColor = expiryColor(days: app.daysRemaining)
                        RoundedRectangle(cornerRadius: 17.5)
                            .fill(isRefreshing ? bgColor.opacity(0.15) : bgColor)
                        if isRefreshing {
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 17.5)
                                    .fill(bgColor)
                                    .frame(width: max(0, geo.size.width * manager.refreshFraction))
                            }
                            .transition(.opacity)
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                                .transition(.opacity)
                        }
                        Text("\(app.daysRemaining) 天")
                            .font(.system(size: 14, weight: .bold))
                            .bold()
                            .foregroundColor(isRefreshing ? .clear : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .frame(width: 77, height: 35)
                    .contentShape(RoundedRectangle(cornerRadius: 17.5))
                    .animation(.linear(duration: 0.25), value: manager.refreshFraction)
                    .animation(.easeInOut(duration: 0.2), value: manager.currentlyRefreshingBundleId)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(manager.isRefreshing)
                .accessibilityLabel("刷新 \(app.name)")
            }
        }
        .padding()
        .background(Color.teal.opacity(0.08))
        .cornerRadius(20)
        .appCardContextMenu(
            info: AppCardInfo(
                name: app.name,
                bundleId: app.bundleId,
                team: app.team,
                expiresDate: app.expiresDate,
                isExternal: false,
                hasSavedIPA: app.ipaPath.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                hasImportedIcon: manager.externalIconPath(for: app.bundleId) != nil ||
                    (app.iconPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            ),
            canRefresh: true,
            isBusy: manager.isRefreshing || manager.isRefreshingExternal,
            onRefresh: {
                Task { await manager.refreshApp(app) }
            },
            onChangeIcon: onChangeIcon
        )
    }

}

private struct AppCardInfo {
    let name: String
    let bundleId: String
    let team: String?
    let expiresDate: Date?
    let isExternal: Bool
    let hasSavedIPA: Bool?
    let hasImportedIcon: Bool
}

private struct AppCardContextMenuModifier: ViewModifier {
    let info: AppCardInfo
    let canRefresh: Bool
    let isBusy: Bool
    let onRefresh: () -> Void
    let onChangeIcon: () -> Void
    @State private var isShowingInfo = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(action: onRefresh) {
                    Label(
                        canRefresh ? "刷新" : "刷新（尚未加入刷新清單）",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!canRefresh || isBusy)

                Button {} label: {
                    Label("重新簽名（尚未支援）", systemImage: "signature")
                }
                .disabled(true)

                Button {} label: {
                    Label("重新安裝（尚未支援）", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(true)

                Button {} label: {
                    Label("描述檔（尚未支援）", systemImage: "doc.plaintext")
                }
                .disabled(true)

                Button(action: onChangeIcon) {
                    Label("變更卡片圖示", systemImage: "photo")
                }

                Button {
                    isShowingInfo = true
                } label: {
                    Label("資訊", systemImage: "info.circle")
                }
            }
            .sheet(isPresented: $isShowingInfo) {
                AppCardInfoSheet(info: info)
            }
    }
}

private extension View {
    func appCardContextMenu(
        info: AppCardInfo,
        canRefresh: Bool,
        isBusy: Bool,
        onRefresh: @escaping () -> Void,
        onChangeIcon: @escaping () -> Void
    ) -> some View {
        modifier(AppCardContextMenuModifier(
            info: info,
            canRefresh: canRefresh,
            isBusy: isBusy,
            onRefresh: onRefresh,
            onChangeIcon: onChangeIcon
        ))
    }
}

private struct AppCardInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let info: AppCardInfo

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("App")) {
                    detailRow("名稱", value: info.name)
                    detailRow("Bundle ID", value: info.bundleId)
                    detailRow("類型", value: info.isExternal ? "外部 App" : "EiliStore 安裝")
                }

                Section(header: Text("本機紀錄")) {
                    detailRow("Team", value: info.team.flatMap { $0 == "未知" || $0.isEmpty ? nil : $0 } ?? "未記錄")
                    if let expiresDate = info.expiresDate {
                        detailRow("記錄的到期日", value: expiresDate.formatted(date: .long, time: .omitted))
                    } else {
                        detailRow("記錄的到期日", value: "未記錄")
                    }
                    detailRow("匯入的卡片圖示", value: info.hasImportedIcon ? "有" : "沒有")
                    if let hasSavedIPA = info.hasSavedIPA {
                        detailRow("保存的 IPA", value: hasSavedIPA ? "可用" : "不存在")
                    }
                }

                Section {
                    Text("到期日是 EiliStore 的本機資料，不代表已讀取裝置上的 provisioning profile 檔案。變更卡片圖示只影響 EiliStore 清單，不會更改裝置主畫面圖示。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("App 資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 軟體源（已移至 SourcesView.swift）

// MARK: - 簽名
struct SignInstallView: View {
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("簽名")) {
                    NavigationLink(destination: SignIPAView()) {
                        Label("匯入 IPA 並簽名安裝", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink(destination: SigningFlowView()) {
                        Text("簽名 IPA")
                    }
                }
                
                Section(header: Text("安裝")) {
                    NavigationLink(destination: InstallAppView()) {
                        Text("安裝 App")
                    }
                }
            }
            .navigationTitle("簽名")
        }
    }
}

// MARK: - 設定
struct SettingsView: View {
    @State private var appleID = ""
    @State private var isLoggedIn = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("賬號")) {
                    if isLoggedIn {
                        NavigationLink(destination: AccountView(appleID: $appleID, isLoggedIn: $isLoggedIn)) {
                            Text("已登入: \(appleID)")
                        }
                    } else {
                        NavigationLink(destination: LoginView(appleID: $appleID, isLoggedIn: $isLoggedIn)) {
                            Text("Apple ID 登入")
                        }
                    }
                }
                
                Section(header: Text("Developer Portal Services")) {
                    NavigationLink(destination: DeveloperPortalView()) {
                        Label("Developer Portal", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(!isLoggedIn)
                    if !isLoggedIn {
                        Text("請先登入 Apple ID，再管理開發者團隊資源。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("證書")) {
                    NavigationLink(destination: CertificateView()) {
                        Text("證書管理")
                    }
                    NavigationLink(destination: AppIDsView()) {
                        Text("App ID 管理")
                    }
                }
                
                Section(header: Text("調試")) {
                    NavigationLink(destination: AnisetteServerView()) {
                        Text("Anisette 伺服器")
                    }
                    NavigationLink(destination: ConnectionConfigView()) {
                        Text("連接配置")
                    }
                    NavigationLink(destination: PairingFileManagementView()) {
                        Text("配對檔管理")
                    }
                    NavigationLink(destination: FileBrowserView(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)) {
                        Text("檔案管理")
                    }
                }
                
                Section(header: Text("關於")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: LogView()) {
                        Text("日誌")
                    }
                }
            }
            .navigationTitle("設定")
            .onAppear {
                if PaxAuthService.shared.hasSavedSession,
                   let savedID = PaxAuthService.shared.currentAppleID,
                   !savedID.isEmpty {
                    isLoggedIn = true
                    appleID = savedID
                } else {
                    isLoggedIn = false
                    appleID = ""
                }
            }
        }
    }

}
struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }

}
