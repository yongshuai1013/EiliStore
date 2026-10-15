import UIKit

/// 用 LSApplicationWorkspace 按 bundle ID 拿已安裝 App 的圖標
class AppIconHelper {
    static let shared = AppIconHelper()
    
    private var workspace: NSObject? {
        let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type
        return cls?.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
    }
    
    /// 返回 App 圖標，找不到返回 nil
    func icon(for bundleId: String) -> UIImage? {
        guard let ws = workspace else { return nil }
        // applicationForBundleIdentifier:
        let sel = NSSelectorFromString("applicationForBundleIdentifier:")
        guard ws.responds(to: sel) else { return nil }
        guard let appProxy = ws.perform(sel, with: bundleId)?.takeUnretainedValue() as? NSObject else { return nil }
        // icons property
        let iconsSel = NSSelectorFromString("icons")
        guard appProxy.responds(to: iconsSel) else { return nil }
        guard let icons = appProxy.perform(iconsSel)?.takeUnretainedValue() as? [NSObject] else { return nil }
        for icon in icons {
            // imageForSize: or similar - try common selectors
            for selName in ["imageForSize:", "_imageForSize:"] {
                let s = NSSelectorFromString(selName)
                if icon.responds(to: s) {
                    let size = CGSize(width: 120, height: 120)
                    if let img = icon.perform(s, with: NSValue(cgSize: size))?.takeUnretainedValue() as? UIImage {
                        return img
                    }
                }
            }
        }
        return nil
    }
}
