import Foundation
import UIKit
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
        
        // 直接讀 PNG 或從編譯後的 Assets.car 載入 AppIcon；解析只讀取 IPA，
        // 不驗證其簽章，也不會安裝或簽名 App。
        let iconData = extractIconData(from: appURL, plist: plist)

        return AppInfo(name: name, bundleId: bundleId, version: version, iconData: iconData)
    }

    private static func extractIconData(from appURL: URL, plist: [String: Any]) -> Data? {
        var iconNames: [String] = []
        let iconDictionaryKeys = ["CFBundleIcons", "CFBundleIcons~iphone", "CFBundleIcons~ipad"]

        for key in iconDictionaryKeys {
            guard let icons = plist[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else {
                continue
            }
            if let name = primary["CFBundleIconName"] as? String {
                iconNames.append(name)
            }
            if let files = primary["CFBundleIconFiles"] as? [String] {
                iconNames.append(contentsOf: files)
            }
        }
        if let name = plist["CFBundleIconName"] as? String {
            iconNames.append(name)
        }

        // 先透過 Bundle 讀取 Assets.car 中的圖示，再嘗試 IPA 內的 PNG 檔。
        if let appBundle = Bundle(path: appURL.path) {
            for name in iconNames + ["AppIcon", "AppIcon60x60"] {
                if let image = UIImage(named: name, in: appBundle, compatibleWith: nil),
                   let data = image.pngData() {
                    return data
                }
            }
        }

        for name in iconNames {
            let baseName = (name as NSString).deletingPathExtension
            let candidates = [name, "\(baseName)@3x", "\(baseName)@2x"]
            for candidate in candidates {
                let fileName = candidate.hasSuffix(".png") ? candidate : "\(candidate).png"
                let iconURL = appURL.appendingPathComponent(fileName)
                if let data = try? Data(contentsOf: iconURL), UIImage(data: data) != nil {
                    return data
                }
            }
        }
        return nil
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
