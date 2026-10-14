import Foundation

/// Anisette 伺服器
public struct AnisetteServer: Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let url: String
    
    public init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
    
    public var nsURL: URL? { URL(string: url) }
}

/// Catalog JSON 格式
private struct ServerCatalog: Codable {
    struct Entry: Codable {
        let name: String
        let address: String
    }
    let servers: [Entry]
}

/// Server 選擇管理（支援 catalog、排序、隱藏、自動輪換）
public final class AnisetteServerManager {
    public static let shared = AnisetteServerManager()
    
    private let selectedKey = "paxstore.anisette.selectedServerID"
    private let customKey = "paxstore.anisette.customServers"
    private let catalogURLKey = "paxstore.anisette.catalogURL"
    private let orderKey = "paxstore.anisette.order"
    private let hiddenKey = "paxstore.anisette.hidden"
    private let autoRotateKey = "paxstore.anisette.autoRotate"
    private let cachedCatalogKey = "paxstore.anisette.cachedCatalog"
    
    public let defaultCatalogURL = "https://servers.sidestore.io/servers.json"
    
    private init() {}
    
    // MARK: - Catalog URL
    
    public var catalogURL: String {
        get { UserDefaults.standard.string(forKey: catalogURLKey) ?? defaultCatalogURL }
        set { UserDefaults.standard.set(newValue, forKey: catalogURLKey) }
    }
    
    // MARK: - Auto Rotation
    
    public var autoRotationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoRotateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoRotateKey) }
    }
    
    // MARK: - Server 列表
    
    /// 從 catalog 抓到的 server（快取）
    private var cachedCatalogServers: [AnisetteServer] {
        get {
            guard let data = UserDefaults.standard.data(forKey: cachedCatalogKey),
                  let servers = try? JSONDecoder().decode([AnisetteServer].self, from: data) else {
                return []
            }
            return servers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: cachedCatalogKey)
            }
        }
    }
    
    /// 自訂伺服器
    public var customServers: [AnisetteServer] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customKey),
                  let servers = try? JSONDecoder().decode([AnisetteServer].self, from: data) else {
                return []
            }
            return servers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: customKey)
            }
        }
    }
    
    /// 所有 server（catalog＋自訂），按用戶排序
    public var allServers: [AnisetteServer] {
        let all = cachedCatalogServers + customServers
        let order = serverOrder
        // 按 order 排序，沒在 order 裡的放後面
        return all.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
    }
    
    /// 可見的 server（沒被隱藏的）
    public var visibleServers: [AnisetteServer] {
        let hidden = hiddenIDs
        return allServers.filter { !hidden.contains($0.id) }
    }
    
    /// 用戶自訂排序（server id 陣列）
    private var serverOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: orderKey) }
    }
    
    /// 被隱藏的 server id
    private var hiddenIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }
    
    public func isHidden(_ server: AnisetteServer) -> Bool {
        hiddenIDs.contains(server.id)
    }
    
    public func setHidden(_ server: AnisetteServer, hidden: Bool) {
        var ids = hiddenIDs
        if hidden {
            ids.insert(server.id)
        } else {
            ids.remove(server.id)
        }
        hiddenIDs = ids
    }
    
    public func moveServers(from source: IndexSet, to destination: Int) {
        var ordered = allServers
        ordered.move(fromOffsets: source, toOffset: destination)
        serverOrder = ordered.map { $0.id }
    }
    
    // MARK: - 選擇
    
    public var selectedServer: AnisetteServer {
        let id = UserDefaults.standard.string(forKey: selectedKey)
        if let id = id, let s = allServers.first(where: { $0.id == id }) {
            return s
        }
        // 預設選 sidestore.zip
        return allServers.first(where: { $0.url.contains("sidestore.zip") })
            ?? visibleServers.first
            ?? AnisetteServer(id: "fallback", name: "SideStore (.zip)", url: "https://ani.sidestore.zip")
    }
    
    public func select(_ server: AnisetteServer) {
        UserDefaults.standard.set(server.id, forKey: selectedKey)
    }
    
    // MARK: - 自訂
    
    public func addCustom(name: String, url: String) {
        var customs = customServers
        let server = AnisetteServer(name: name, url: url)
        customs.append(server)
        customServers = customs
        // 加到排序末尾
        serverOrder = allServers.map { $0.id }
    }
    
    public func removeCustom(_ server: AnisetteServer) {
        customServers = customServers.filter { $0.id != server.id }
        if selectedServer.id == server.id {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }
    
    // MARK: - Catalog 抓取
    
    /// 從 catalog URL 抓取 server 列表
    public func refreshCatalog() async throws {
        guard let url = URL(string: catalogURL) else {
            throw NSError(domain: "PaxStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Catalog URL 無效"])
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let catalog = try JSONDecoder().decode(ServerCatalog.self, from: data)
        let servers = catalog.servers.map { entry in
            // 用 url 當穩定 id
            AnisetteServer(id: "catalog-\(entry.address)", name: entry.name, url: entry.address)
        }
        cachedCatalogServers = servers
        // 新 server 加到排序末尾（保留用戶已排的順序）
        var order = serverOrder
        for s in servers where !order.contains(s.id) {
            order.append(s.id)
        }
        serverOrder = order
    }
    
    // MARK: - 登入用
    
    /// 登入時用的 server 列表（自動輪換開→按優先順序全部可見的；關→只用選中的）
    public func serversForLogin() -> [URL] {
        if autoRotationEnabled {
            return visibleServers.compactMap { $0.nsURL }
        } else {
            guard let url = selectedServer.nsURL else { return [] }
            return [url]
        }
    }
}
