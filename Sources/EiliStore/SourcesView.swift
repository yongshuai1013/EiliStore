import SwiftUI

/// 軟體源頁
struct SourcesView: View {
    @StateObject private var manager = SourceManager.shared
    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newURL = ""
    
    var body: some View {
        NavigationView {
            List {
                if manager.sources.isEmpty {
                    Section {
                        Text("還沒有添加軟體源")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(manager.sources) { source in
                        NavigationLink(destination: SourceDetailView(source: source)) {
                            VStack(alignment: .leading) {
                                Text(source.name)
                                    .font(.headline)
                                Text("\(source.apps.count) 個 App")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            manager.removeSource(id: manager.sources[index].id)
                        }
                    }
                }
            }
            .navigationTitle("軟體源")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                NavigationView {
                    Form {
                        Section("名稱") {
                            TextField("源名稱", text: $newName)
                        }
                        Section("URL") {
                            TextField("https://...", text: $newURL)
                                .autocapitalization(.none)
                                .keyboardType(.URL)
                        }
                    }
                    .navigationTitle("添加軟體源")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showAddSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加") {
                                if !newName.isEmpty && !newURL.isEmpty {
                                    manager.addSource(name: newName, url: newURL)
                                    newName = ""
                                    newURL = ""
                                    showAddSheet = false
                                }
                            }
                        }
                    }
                }
            }
        }
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
