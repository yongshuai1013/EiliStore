import UIKit

/// 用 LSApplicationWorkspace 按 bundle ID 拿已安裝 App 的圖標
class AppIconHelper {
    static let shared = AppIconHelper()
    
    /// 返回 App 圖標，找不到返回 nil
    func icon(for bundleId: String) -> UIImage? {
        // 方法1: 試著從 LSApplicationWorkspace 拿 bundle URL，再讀圖標
        if let icon = iconViaWorkspace(bundleId: bundleId) {
            return icon
        }
        return nil
    }
    
    /// 返回 App 名稱，找不到返回 nil
    func appName(for bundleId: String) -> String? {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let sel = NSSelectorFromString("allInstalledApplications")
        guard ws.responds(to: sel),
              let apps = ws.perform(sel)?.takeUnretainedValue() as? [NSObject] else {
            return nil
        }
        for app in apps {
            let bidSel = NSSelectorFromString("bundleIdentifier")
            guard app.responds(to: bidSel),
                  let bid = app.perform(bidSel)?.takeUnretainedValue() as? String,
                  bid == bundleId else {
                continue
            }
            // 試 localizedName / name
            for nameSel in ["localizedName", "appName", "name"] {
                let s = NSSelectorFromString(nameSel)
                if app.responds(to: s),
                   let name = app.perform(s)?.takeUnretainedValue() as? String,
                   !name.isEmpty {
                    return name
                }
            }
            return nil
        }
        return nil
    }
    
    private func iconViaWorkspace(bundleId: String) -> UIImage? {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        
        // 拿所有已安裝 App，找到對應 bundle ID 的
        let sel = NSSelectorFromString("allInstalledApplications")
        guard ws.responds(to: sel),
              let apps = ws.perform(sel)?.takeUnretainedValue() as? [NSObject] else {
            return nil
        }
        
        for app in apps {
            // bundleIdentifier
            let bidSel = NSSelectorFromString("bundleIdentifier")
            guard app.responds(to: bidSel),
                  let bid = app.perform(bidSel)?.takeUnretainedValue() as? String,
                  bid == bundleId else {
                continue
            }
            
            // bundleURL
            let urlSel = NSSelectorFromString("bundleURL")
            guard app.responds(to: urlSel),
                  let bundleURL = app.perform(urlSel)?.takeUnretainedValue() as? URL else {
                continue
            }
            
            // 讀 Info.plist 找圖標
            return iconFromBundle(at: bundleURL)
        }
        return nil
    }
    
    private func iconFromBundle(at bundleURL: URL) -> UIImage? {
        let fm = FileManager.default
        let infoPlist = bundleURL.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist) else { return nil }
        
        // 試 CFBundleIcons
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let first = files.first {
            // 試幾個可能的後綴
            for suffix in ["", "@2x", "@3x"] {
                for ext in ["png", ""] {
                    let name = first + suffix + (ext.isEmpty ? "" : "." + ext)
                    let url = bundleURL.appendingPathComponent(name)
                    if fm.fileExists(atPath: url.path),
                       let img = UIImage(contentsOfFile: url.path) {
                        return img
                    }
                }
            }
        }
        
        // 試直接找 Icon.png / AppIcon
        for name in ["AppIcon60x60@3x.png", "AppIcon60x60@2x.png", "Icon-60@3x.png", "Icon-60@2x.png", "Icon.png"] {
            let url = bundleURL.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path),
               let img = UIImage(contentsOfFile: url.path) {
                return img
            }
        }
        
        return nil
    }
}
