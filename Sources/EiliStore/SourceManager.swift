import Foundation
import SwiftUI

/// 軟體源
struct AppSource: Identifiable, Codable {
    let id: UUID
    var name: String
    var url: String
    var apps: [SourceApp]
    
    init(id: UUID = UUID(), name: String, url: String, apps: [SourceApp] = []) {
        self.id = id
        self.name = name
        self.url = url
        self.apps = apps
    }
}

/// 源裡的 App
struct SourceApp: Identifiable, Codable {
    let id: String
    var name: String
    var bundleId: String
    var version: String
    var downloadURL: String
    var iconURL: String?
    var description: String?
    
    init(id: String = UUID().uuidString, name: String, bundleId: String, version: String, downloadURL: String, iconURL: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.version = version
        self.downloadURL = downloadURL
        self.iconURL = iconURL
        self.description = description
    }
}

/// 軟體源管理器
class SourceManager: ObservableObject {
    static let shared = SourceManager()
    
    @Published var sources: [AppSource] = []
    
    private let saveKey = "eilistore.sources"
    
    private init() {
        load()
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([AppSource].self, from: data) {
            sources = decoded
        }
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }
    
    func addSource(name: String, url: String) {
        let source = AppSource(name: name, url: url)
        sources.append(source)
        save()
        AppLogger.shared.log("已添加軟體源: \(name)")
        
        // 異步獲取源內容
        Task {
            await fetchSource(source)
        }
    }
    
    func removeSource(id: UUID) {
        if let source = sources.first(where: { $0.id == id }) {
            AppLogger.shared.log("已刪除軟體源: \(source.name)")
        }
        sources.removeAll { $0.id == id }
        save()
    }
    
    /// 獲取源內容（SideStore 格式的 JSON）
    func fetchSource(_ source: AppSource) async {
        AppLogger.shared.log("正在獲取軟體源: \(source.name)...")
        
        guard let url = URL(string: source.url) else {
            AppLogger.shared.log("❌ 源 URL 無效: \(source.url)")
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // TODO: 解析 SideStore 格式的 JSON
            // 現在先記錄獲取成功
            AppLogger.shared.log("✅ 源獲取成功 (\(data.count) bytes)，解析待實現")
        } catch {
            AppLogger.shared.log("❌ 源獲取失敗: \(error.localizedDescription)")
        }
    }
    
    func refreshAll() async {
        for source in sources {
            await fetchSource(source)
        }
    }
}
