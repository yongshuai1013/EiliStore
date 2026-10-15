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

// MARK: - 檔案剪貼簿（App 內複製／貼上）
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()
    @Published var copiedURL: URL?
    private init() {}
}

// MARK: - 檔案剪貼簿（App 內複製／貼上）
final class FileClipboard: ObservableObject {
    static let shared = FileClipboard()
    @Published var copiedURL: URL?
    private init() {}
}

/// 分享項包裝（讓 sheet(item:) 可用）
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct FileBrowserView: View {
    let directory: URL
    @State private var items: [URL] = []
    @StateObject private var clipboard = FileClipboard.shared

    @State private var shareItem: ShareItem?
    @State private var renameURL: URL?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(items, id: \.self) { url in
                if isDirectory(url) {
                    NavigationLink(destination: FileBrowserView(directory: url)) {
                        fileRow(url: url, isDir: true)
                    }
                    .contextMenu { folderMenu(url) }
                } else {
                    fileRow(url: url, isDir: false)
                        .contextMenu { fileMenu(url) }
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle(directory.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if clipboard.copiedURL != nil {
                    Button("貼上") { paste() }
                }
            }
        }
        // 用 sheet(item:) 確保 URL 非空，避免白屏
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
        .alert("重新命名", isPresented: $showRenameAlert) {
            TextField("名稱", text: $renameText)
            Button("確定") { doRename() }
            Button("取消", role: .cancel) { }
        }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("確定", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { load() }
    }

    // MARK: - 行 UI（仿系統檔案 App）

    @ViewBuilder
    private func fileRow(url: URL, isDir: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: url, isDir: isDir))
                .font(.title2)
                .foregroundColor(isDir ? .blue : iconColor(for: url))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(isDir ? "資料夾" : fileSizeString(url))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !isDir {
                Button {
                    shareItem = ShareItem(url: url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.teal)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private func iconName(for url: URL, isDir: Bool) -> String {
        if isDir { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "ipa": return "app.badge.fill"
        case "plist": return "doc.text.fill"
        case "json": return "curlybraces"
        case "txt", "log": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo.fill"
        case "mp4", "mov": return "video.fill"
        case "mp3", "m4a", "wav": return "music.note"
        case "zip": return "archivebox.fill"
        case "crt", "cer", "p12": return "lock.doc.fill"
        default: return "doc.fill"
        }
    }

    private func iconColor(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "ipa": return .teal
        case "png", "jpg", "jpeg", "gif", "webp": return .green
        case "mp4", "mov": return .purple
        case "mp3", "m4a", "wav": return .pink
        default: return .gray
        }
    }

    // MARK: - 長按選單

    @ViewBuilder
    private func fileMenu(_ url: URL) -> some View {
        Button(action: { clipboard.copiedURL = url }) {
            Label("複製", systemImage: "doc.on.doc")
        }
        Button(action: { beginRename(url) }) {
            Label("重新命名", systemImage: "pencil")
        }
        Button(action: { shareItem = ShareItem(url: url) }) {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive, action: {
            try? FileManager.default.removeItem(at: url)
            load()
        }) {
            Label("刪除", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func folderMenu(_ url: URL) -> some View {
        Button(action: { beginRename(url) }) {
            Label("重新命名", systemImage: "pencil")
        }
        Button(role: .destructive, action: {
            try? FileManager.default.removeItem(at: url)
            load()
        }) {
            Label("刪除", systemImage: "trash")
        }
    }

    // MARK: - 操作

    private func beginRename(_ url: URL) {
        renameURL = url
        if isDirectory(url) {
            renameText = url.lastPathComponent
        } else {
            renameText = url.deletingPathExtension().lastPathComponent
        }
        showRenameAlert = true
    }

    private func doRename() {
        guard let url = renameURL, !renameText.isEmpty else { return }
        let newName: String
        if isDirectory(url) {
            newName = renameText
        } else {
            let ext = url.pathExtension
            newName = ext.isEmpty ? renameText : "\(renameText).\(ext)"
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard dest != url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                throw NSError(domain: "FileBrowser", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "同名檔案已存在"])
            }
            try FileManager.default.moveItem(at: url, to: dest)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
        renameURL = nil
    }

    private func paste() {
        guard let src = clipboard.copiedURL else { return }
        var dest = directory.appendingPathComponent(src.lastPathComponent)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            let name = ext.isEmpty ? "\(base) 副本\(n)" : "\(base) 副本\(n).\(ext)"
            dest = directory.appendingPathComponent(name)
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            // 貼上成功後清空剪貼簿
            clipboard.copiedURL = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
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

