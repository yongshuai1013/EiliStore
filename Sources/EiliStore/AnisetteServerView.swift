import SwiftUI

struct AnisetteServerView: View {
    @State private var servers: [AnisetteServer] = AnisetteServerManager.shared.allServers
    @State private var selectedID: String = AnisetteServerManager.shared.selectedServer.id
    @State private var autoRotate: Bool = AnisetteServerManager.shared.autoRotationEnabled
    @State private var catalogURL: String = AnisetteServerManager.shared.catalogURL
    @State private var showingAdd = false
    @State private var showingEditCatalog = false
    @State private var editCatalogURL = ""
    @State private var newName = ""
    @State private var newURL = ""
    @State private var isRefreshing = false
    @State private var refreshError: String?
    
    private let manager = AnisetteServerManager.shared
    
    var body: some View {
        List {
            Section(header: Text("AVAILABLE SERVERS"),
                    footer: Text("Drag to reorder server priority. Swipe left on a server to hide or unhide it.")) {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    serverRow(index: index, server: server)
                }
                .onMove(perform: moveServers)
            }
            
            Section(header: HStack {
                Text("SERVER CATALOG SOURCE")
                Spacer()
                Button("EDIT") {
                    showingEditCatalog = true
                }
                .foregroundColor(.purple)
                .font(.caption.bold())
            }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server List URL")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(catalogURL)
                        .font(.body)
                }
                .contextMenu {
                    Button("複製 URL") {
                        UIPasteboard.general.string = catalogURL
                    }
                }
            }
            
            Section(footer: Text("URL of the JSON file containing registered Anisette servers. Press and hold row to export.")) {
                EmptyView()
            }
            
            Section(header: Text("CUSTOMIZATION")) {
                Toggle(isOn: $autoRotate) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.purple)
                        Text("Enable Auto Rotation")
                    }
                }
                .onChange(of: autoRotate) { newValue in
                    manager.autoRotationEnabled = newValue
                }
            }
            
            Section(footer: Text("Control if PaxStore automatically rotates/retries servers upon failure.")) {
                EmptyView()
            }
        }
        .navigationTitle("Anisette 伺服器")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(action: refreshCatalog) {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationView {
                Form {
                    TextField("名稱", text: $newName)
                    TextField("URL（https://...）", text: $newURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }
                .navigationTitle("新增伺服器")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("加入") {
                            guard !newName.isEmpty, !newURL.isEmpty,
                                  URL(string: newURL) != nil else { return }
                            manager.addCustom(name: newName, url: newURL)
                            newName = ""
                            newURL = ""
                            showingAdd = false
                            refresh()
                        }
                    }
                }
            }
        }
        .alert("編輯 Catalog 來源", isPresented: $showingEditCatalog) {
            TextField("Server List URL", text: $editCatalogURL)
                .autocapitalization(.none)
                .keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("儲存") {
                if !editCatalogURL.isEmpty, URL(string: editCatalogURL) != nil {
                    manager.catalogURL = editCatalogURL
                    catalogURL = editCatalogURL
                }
            }
        } message: {
            Text("修改後點右上角刷新按鈕重新抓取")
        }
        .alert("刷新失敗", isPresented: .constant(refreshError != nil)) {
            Button("好") { refreshError = nil }
        } message: {
            Text(refreshError ?? "")
        }
        .onAppear {
            editCatalogURL = catalogURL
            refresh()
            // 首次進來自動抓一次 catalog
            if manager.allServers.isEmpty {
                refreshCatalog()
            }
        }
    }
    
    private func serverRow(index: Int, server: AnisetteServer) -> some View {
        let hidden = manager.isHidden(server)
        return Button(action: {
            manager.select(server)
            selectedID = server.id
        }) {
            HStack {
                Text("#\(index + 1)")
                    .foregroundColor(.gray)
                    .font(.caption)
                    .frame(width: 35, alignment: .leading)
                VStack(alignment: .leading) {
                    Text(server.name)
                        .foregroundColor(hidden ? .gray : .primary)
                        .strikethrough(hidden)
                    Text(server.url)
                        .foregroundColor(.gray)
                        .font(.caption)
                }
                Spacer()
                if hidden {
                    Text("已隱藏")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if server.id == selectedID {
                    Image(systemName: "checkmark")
                        .foregroundColor(.purple)
                }
            }
        }
        .contextMenu {
            Button("複製 URL") {
                UIPasteboard.general.string = server.url
            }
            Button("複製 名稱+URL") {
                UIPasteboard.general.string = "\(server.name)\n\(server.url)"
            }
        }
        .swipeActions(edge: .trailing) {
            // 自訂的（UUID id）可以刪除，catalog 來的不行
            if UUID(uuidString: server.id) != nil {
                Button(role: .destructive) {
                    manager.removeCustom(server)
                    refresh()
                } label: {
                    Label("刪除", systemImage: "trash")
                }
            }
            Button {
                manager.setHidden(server, hidden: !hidden)
                refresh()
            } label: {
                Label(hidden ? "取消隱藏" : "隱藏", systemImage: hidden ? "eye" : "eye.slash")
            }
            .tint(hidden ? .green : .orange)
        }
    }
    
    private func moveServers(from source: IndexSet, to destination: Int) {
        manager.moveServers(from: source, to: destination)
        refresh()
    }
    
    private func refresh() {
        servers = manager.allServers
        selectedID = manager.selectedServer.id
        autoRotate = manager.autoRotationEnabled
        catalogURL = manager.catalogURL
    }
    
    private func refreshCatalog() {
        isRefreshing = true
        refreshError = nil
        Task {
            do {
                try await manager.refreshCatalog()
                await MainActor.run {
                    isRefreshing = false
                    refresh()
                }
            } catch {
                await MainActor.run {
                    isRefreshing = false
                    refreshError = error.localizedDescription
                }
            }
        }
    }
}
