import SwiftUI

// MARK: - 檔案管理（App 沙盒內部檔案瀏覽）
struct FileManagerRootView: View {
    var body: some View {
        let fm = FileManager.default
        let home = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .deletingLastPathComponent()
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let tmp = fm.temporaryDirectory
        return Form {
            Section(header: Text("沙盒目錄")) {
                NavigationLink(destination: FileBrowserView(directory: docs)) {
                    Label("Documents", systemImage: "folder.fill")
                }
                NavigationLink(destination: FileBrowserView(directory: lib)) {
                    Label("Library", systemImage: "folder.fill")
                }
                NavigationLink(destination: FileBrowserView(directory: tmp)) {
                    Label("tmp", systemImage: "folder.fill")
                }
            }
            Section(footer: Text("左滑可刪除檔案／資料夾")) {
                EmptyView()
            }
        }
        .navigationTitle("檔案管理")
    }
}

struct FileBrowserView: View {
    let directory: URL
    @State private var items: [URL] = []
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        List {
            ForEach(items, id: \.self) { url in
                if isDirectory(url) {
                    NavigationLink(destination: FileBrowserView(directory: url)) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                            Text(url.lastPathComponent)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.gray)
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Text(fileSizeString(url))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            shareURL = url
                            showShare = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle(directory.lastPathComponent)
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(url: url)
            }
        }
        .onAppear { load() }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private func fileSizeString(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1024 / 1024)
    }

    private func load() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        items = contents.sorted {
            let d0 = isDirectory($0), d1 = isDirectory($1)
            if d0 != d1 { return d0 && !d1 }
            return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            try? FileManager.default.removeItem(at: items[i])
        }
        load()
    }
}
