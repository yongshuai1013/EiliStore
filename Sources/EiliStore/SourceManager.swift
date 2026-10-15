import Foundation
import SwiftUI

/// 軟體源
struct AppSource: Identifiable, Codable {
    let id: UUID
    var name: String
    var url: String
    var apps: [SourceApp]
    var lastUpdated: Date?
    
    init(id: UUID = UUID(), name: String, url: String, apps: [SourceApp] = [], lastUpdated: Date? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.apps = apps
        self.lastUpdated = lastUpdated
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
    var developerName: String?
    
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
    
    /// GitHub 頁面連結轉 raw 連結（貼 github.com/.../blob/... 也能用）
    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("github.com") && s.contains("/blob/") {
            s = s.replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com")
            s = s.replacingOccurrences(of: "/blob/", with: "/")
        }
        return s
    }

    /// 獲取源內容（SideStore/AltStore 格式的 JSON）
    func fetchSource(_ source: AppSource) async {
        AppLogger.shared.log("正在獲取軟體源: \(source.name)...")

        let urlString = Self.normalizeURL(source.url)
        guard let url = URL(string: urlString) else {
            AppLogger.shared.log("❌ 源 URL 無效: \(source.url)")
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = try parseSourceJSON(data)
            await MainActor.run {
                if let idx = self.sources.firstIndex(where: { $0.id == source.id }) {
                    self.sources[idx].apps = parsed.apps
                    if let name = parsed.name, !name.isEmpty {
                        self.sources[idx].name = name
                    }
                    self.sources[idx].lastUpdated = Date()
                    self.save()
                }
            }
            AppLogger.shared.log("✅ 源獲取成功: \(source.name)，\(parsed.apps.count) 個 App")
        } catch {
            AppLogger.shared.log("❌ 源獲取失敗: \(error.localizedDescription)")
        }
    }

    /// 解析 SideStore/AltStore 源 JSON
    private func parseSourceJSON(_ data: Data) throws -> (name: String?, apps: [SourceApp]) {
        let decoder = JSONDecoder()
        let json = try decoder.decode(SourceJSON.self, from: data)
        var apps: [SourceApp] = []
        for entry in json.apps ?? [] {
            // 新格式取 versions[0]，舊格式用平鋪欄位
            let v = entry.versions?.first
            let version = v?.version ?? entry.version ?? ""
            let downloadURL = v?.downloadURL ?? entry.downloadURL ?? ""
            guard let name = entry.name, !name.isEmpty,
                  let bundleId = entry.bundleIdentifier, !bundleId.isEmpty,
                  !downloadURL.isEmpty else { continue }
            apps.append(SourceApp(
                name: name,
                bundleId: bundleId,
                version: version,
                downloadURL: downloadURL,
                iconURL: entry.iconURL,
                description: entry.localizedDescription ?? entry.subtitle,
                developerName: entry.developerName
            ))
        }
        return (json.name, apps)
    }
    
    func refreshAll() async {
        for source in sources {
            await fetchSource(source)
        }
    }
}

// MARK: - SideStore/AltStore 源 JSON 結構

private struct SourceJSON: Decodable {
    var name: String?
    var apps: [SourceAppJSON]?
}

private struct SourceAppJSON: Decodable {
    var name: String?
    var bundleIdentifier: String?
    var developerName: String?
    var localizedDescription: String?
    var subtitle: String?
    var iconURL: String?
    // 舊格式平鋪欄位
    var version: String?
    var versionDate: String?
    var downloadURL: String?
    var size: Int?
    // 新格式版本陣列（第一個為最新）
    var versions: [SourceVersionJSON]?
}

private struct SourceVersionJSON: Decodable {
    var version: String?
    var date: String?
    var downloadURL: String?
    var size: Int?
    var localizedDescription: String?
}
