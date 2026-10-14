import Foundation
import ZIPFoundation

/// IPA 解析：從 IPA 提取 bundle ID、名稱、圖標
struct IPAParser {
    struct AppInfo {
        let name: String
        let bundleId: String
        let version: String
        let iconData: Data?
    }
    
    /// 解析 IPA，返回 App 信息
    static func parse(ipaURL: URL) throws -> AppInfo {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        
        // 解壓
        try FileManager.default.unzipItem(at: ipaURL, to: workDir)
        
        // 找 .app
        let payload = workDir.appendingPathComponent("Payload")
        let contents = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw IPAError.noAppFound
        }
        
        // 讀 Info.plist
        let infoPlist = appURL.appendingPathComponent("Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw IPAError.invalidPlist
        }
        
        let bundleId = plist["CFBundleIdentifier"] as? String ?? "unknown"
        let name = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let version = plist["CFBundleShortVersionString"] as? String ?? "1.0"
        
        // 找圖標
        var iconData: Data? = nil
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primary["CFBundleIconFiles"] as? [String],
           let iconName = iconFiles.first {
            // 嘗試找 png
            for ext in ["", "@2x", "@3x"] {
                let iconURL = appURL.appendingPathComponent("\(iconName)\(ext).png")
                if let data = try? Data(contentsOf: iconURL) {
                    iconData = data
                    break
                }
            }
        }
        
        return AppInfo(name: name, bundleId: bundleId, version: version, iconData: iconData)
    }
}

enum IPAError: Error, LocalizedError {
    case noAppFound
    case invalidPlist
    
    var errorDescription: String? {
        switch self {
        case .noAppFound: return "IPA 中找不到 .app"
        case .invalidPlist: return "Info.plist 無效"
        }
    }
}
