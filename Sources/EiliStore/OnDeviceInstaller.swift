import Foundation

/// 本機安裝器：直接調用 MobileInstallation 私有 Framework
/// 繞過 VPN/AFC/installation_proxy，用於對比測試
public class OnDeviceInstaller {
    public static let shared = OnDeviceInstaller()
    
    private init() {}
    
    /// 列出 MobileInstallation.framework 導出的相關符號（調試用）
    public func dumpSymbols(progress: @escaping (String, Int) -> Void) async {
        progress("正在載入 MobileInstallation.framework...", 10)
        
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW) else {
            progress("❌ 無法載入 framework", 100)
            return
        }
        defer { dlclose(handle) }
        
        progress("Framework 已載入，探測符號...", 30)
        
        // 嘗試常見的符號名
        let candidates = [
            "MobileInstallationInstall",
            "_MobileInstallationInstall",
            "MobileInstallationUninstall",
            "_MobileInstallationUninstall",
            "MobileInstallationLookup",
            "_MobileInstallationLookup",
            "MICreate",
            "_MICreate",
        ]
        
        var found: [String] = []
        for (i, name) in candidates.enumerated() {
            if dlsym(handle, name) != nil {
                found.append(name)
                progress("✅ 找到: \(name)", 30 + i * 8)
            } else {
                progress("❌ 未找到: \(name)", 30 + i * 8)
            }
        }
        
        if found.isEmpty {
            progress("⚠️ 一個都沒找到，可能符號被 strip 或路徑不對", 100)
        } else {
            progress("✅ 共找到 \(found.count) 個符號", 100)
        }
    }
    
    /// 安裝 IPA（本機直接調用）
    /// - Parameters:
    ///   - ipaURL: IPA 文件 URL（需在 App 可訪問的位置，如 Documents）
    ///   - progress: 進度回調
    public func install(ipaURL: URL, progress: @escaping (String, Int) -> Void) async throws {
        progress("正在載入 MobileInstallation...", 10)
        
        // 動態載入私有 Framework
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW) else {
            throw NSError(domain: "OnDeviceInstall", code: -1, userInfo: [NSLocalizedDescriptionKey: "無法載入 MobileInstallation.framework"])
        }
        defer { dlclose(handle) }
        
        // 獲取函數指針（iOS 符號帶下劃線前綴）
        let sym = dlsym(handle, "MobileInstallationInstall") ?? dlsym(handle, "_MobileInstallationInstall")
        guard let sym = sym else {
            throw NSError(domain: "OnDeviceInstall", code: -2, userInfo: [NSLocalizedDescriptionKey: "找不到 MobileInstallationInstall 符號"])
        }
        
        typealias InstallFunc = @convention(c) (NSString, NSDictionary, UnsafeRawPointer?, UnsafeRawPointer?) -> Int32
        let installFunc = unsafeBitCast(sym, to: InstallFunc.self)
        
        progress("正在安裝（本機）...", 50)
        
        // 構造 options
        let options: NSDictionary = [
            "ApplicationType": "User",
            "PackageType": "Customer"
        ]
        
        // 調用安裝（同步，會阻塞直到完成）
        let result: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let res = installFunc(ipaURL.path as NSString, options, nil, nil)
                continuation.resume(returning: res)
            }
        }
        
        if result == 0 {
            progress("✅ 本機安裝成功", 100)
        } else {
            throw NSError(domain: "OnDeviceInstall", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "本機安裝失敗，錯誤碼: \(result)"])
        }
    }
}
