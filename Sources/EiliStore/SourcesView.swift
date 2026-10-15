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
        ("SideStore 官方源", "apps.sidestore.io/apps.json", "https://apps.sidestore.io/apps.json"),
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.headline)
                        Text("版本 \(app.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let desc = app.description {
                            Text(desc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
