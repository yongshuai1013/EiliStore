import SwiftUI

/// 軟體源頁（SideStore 卡片風格，青色主題）
struct SourcesView: View {
    @StateObject private var manager = SourceManager.shared
    @State private var showAddSheet = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if manager.sources.isEmpty {
                        Text("還沒有添加軟體源，點右上角 + 添加")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(manager.sources) { source in
                            NavigationLink(destination: SourceDetailView(source: source)) {
                                SourceCardView(source: source)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contextMenu {
                                Button("刪除", role: .destructive) {
                                    manager.removeSource(id: source.id)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("軟體源")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(.teal)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddSourceView()
            }
        }
    }
}

/// 源卡片
struct SourceCardView: View {
    let source: AppSource

    private var lastUpdatedText: String {
        guard let date = source.lastUpdated else { return "從未" }
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d"
        return f.string(from: date)
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.25))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "link")
                        .foregroundColor(.white)
                        .font(.title2)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.headline)
                    .bold()
                    .foregroundColor(.white)
                Text("Last Updated: \(lastUpdatedText)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Text("\(source.apps.count)")
                .font(.headline)
                .bold()
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.25))
                .clipShape(Circle())
        }
        .padding()
        .background(
            LinearGradient(
                colors: [.teal, .teal.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(24)
    }
}

/// 添加源（SideStore 樣式）
struct AddSourceView: View {
    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var manager = SourceManager.shared
    @State private var urlText = ""

    private let recommended: [(name: String, subtitle: String, url: String)] = [
        ("SideStore Team Picks", "community-apps.sidestore.io/sidecommunity.json", "https://community-apps.sidestore.io/sidecommunity.json"),
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Add Source")
                        .font(.largeTitle)
                        .bold()
                    Text("Enter a source's URL below, or add one of the recommended sources.")
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .foregroundColor(.teal)
                        TextField("apps.sidestore.io", text: $urlText)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                    }
                    .padding()
                    .background(Color.teal.opacity(0.12))
                    .cornerRadius(24)

                    Button(action: addCustomSource) {
                        Text("添加")
                            .bold()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(urlText.isEmpty ? Color.gray : Color.teal)
                            .cornerRadius(24)
                    }
                    .disabled(urlText.isEmpty)

                    Text("RECOMMENDED SOURCES")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(recommended, id: \.url) { rec in
                        let added = manager.sources.contains(where: { $0.url == rec.url })
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.25))
                                .frame(width: 52, height: 52)
                                .overlay(
                                    Image(systemName: "star.fill")
                                        .foregroundColor(.white)
                                        .font(.title2)
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rec.name)
                                    .font(.headline)
                                    .bold()
                                    .foregroundColor(.white)
                                Text(rec.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            Spacer()
                            Button(action: {
                                if !added {
                                    manager.addSource(name: rec.name, url: rec.url)
                                }
                            }) {
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .foregroundColor(.white)
                                    .font(.title2)
                            }
                            .disabled(added)
                        }
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [.teal, .teal.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .cornerRadius(24)
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }

    private func addCustomSource() {
        var urlString = urlText.trimmingCharacters(in: .whitespaces)
        if !urlString.hasPrefix("http") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString), let host = url.host else { return }
        manager.addSource(name: host, url: urlString)
        urlText = ""
    }
}

/// 源詳情頁
// MARK: - 源詳情（SideStore 樣式 App 列表）
struct SourceDetailView: View {
    let source: AppSource

    var body: some View {
        List {
            if source.apps.isEmpty {
                Section {
                    Text("這個源還沒有 App，或獲取失敗")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(source.apps) { app in
                    NavigationLink(destination: SourceAppDetailView(app: app)) {
                        SourceAppRow(app: app)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - App 行（圖標＋名稱＋版本＋取得按鈕）
struct SourceAppRow: View {
    let app: SourceApp
    @StateObject private var installer = SourceAppInstaller.shared

    private var isInstalled: Bool {
        AppManager.shared.installedApps.contains(where: { $0.bundleId == app.bundleId })
    }

    var body: some View {
        HStack(spacing: 12) {
            SourceAppIcon(urlString: app.iconURL, size: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("版本 \(app.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isInstalled {
                Text("已安裝")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(14)
            } else if installer.isWorking {
                ProgressView()
                    .frame(width: 60)
            } else {
                Button(action: {
                    Task { await installer.install(app) }
                }) {
                    Text("取得")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.teal)
                        .cornerRadius(14)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - App 圖標（遠端載入＋快取）
struct SourceAppIcon: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString = urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(size * 0.22)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(Color.teal.opacity(0.18))
            .overlay(
                Image(systemName: "app.fill")
                    .foregroundColor(.teal)
            )
    }
}

// MARK: - App 詳情頁
struct SourceAppDetailView: View {
    let app: SourceApp
    @StateObject private var installer = SourceAppInstaller.shared

    private var isInstalled: Bool {
        AppManager.shared.installedApps.contains(where: { $0.bundleId == app.bundleId })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 頭部：圖標＋名稱
                HStack(spacing: 16) {
                    SourceAppIcon(urlString: app.iconURL, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title2)
                            .bold()
                        if let dev = app.developerName {
                            Text(dev)
                                .font(.subheadline)
                                .foregroundColor(.teal)
                        }
                        Text("版本 \(app.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                // 安裝按鈕
                if isInstalled {
                    Label("已安裝", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .padding()
                } else if installer.isWorking {
                    VStack(spacing: 8) {
                        if installer.progress >= 0 {
                            ProgressView(value: installer.progress)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                        }
                        Text(installer.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                } else {
                    Button(action: {
                        Task { await installer.install(app) }
                    }) {
                        Text("下載安裝")
                            .bold()
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.teal)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }

                // 狀態訊息（完成／失敗）
                if !installer.isWorking && !installer.statusMessage.isEmpty {
                    Text(installer.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                // 描述
                if let desc = app.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("簡介")
                            .font(.headline)
                        Text(desc)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                // Bundle ID
                VStack(alignment: .leading, spacing: 8) {
                    Text("資訊")
                        .font(.headline)
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(app.bundleId)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

