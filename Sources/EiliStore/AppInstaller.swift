import Foundation

/// App 安裝協調器（經外置 VPN）
/// 使用 PaxStore 的 Swift AFC 路線：上傳 IPA → installation_proxy 安裝
public class AppInstaller {
    public static let shared = AppInstaller()

    private init() {}

    /// 安裝已簽名的 IPA
    public func install(ipaURL: URL, progress: @escaping (String, Int) -> Void) async throws {
        // 1. 檢查 VPN
        progress("檢查 VPN 連線...", 0)
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else { throw InstallerError.vpnNotConnected }
        let host = VPNConnectionChecker.shared.effectiveGatewayHost

        // 2. 找到配對檔
        progress("讀取配對檔...", 5)
        guard let pairingURL = findPairingFile() else { throw InstallerError.noPairingFile }

        // 3. 上傳 IPA (經 Swift AFCClient)
        progress("上傳 IPA...", 20)
        let remoteName = "EiliStore-\(UUID().uuidString.prefix(8)).ipa"
        let stagedPath = "PublicStaging/\(remoteName)"
        let installPath = "/PublicStaging/\(remoteName)"

        // 先拿 AFC 端口（經 lockdownd）
        let tmpLockdown = LockdownClient(host: host)
        try await tmpLockdown.connect(pairingFileURL: pairingURL)
        let (afcPort, afcSSL) = try await tmpLockdown.startService("com.apple.afc")
        guard let afcIdentity = tmpLockdown.identity else {
            tmpLockdown.disconnect()
            throw InstallerError.afcFailed("無法取得配對 identity")
        }
        tmpLockdown.disconnect()

        // AFC 走 10.7.0.1
        let afcHost = "10.7.0.1"
        let afc = AFCClient(host: afcHost)
        do {
            try await afc.connect(port: afcPort, useSSL: afcSSL, identity: afcSSL ? afcIdentity : nil)
            try await afc.uploadFile(localURL: ipaURL, remotePath: stagedPath) { sent, total in
                let pct = total > 0 ? Int(sent * 60 / total) : 0
                progress("上傳 IPA... \(sent / 1024 / 1024)MB / \(total / 1024 / 1024)MB", 20 + pct)
            }
            afc.disconnect()
            progress("上傳完成", 80)
        } catch {
            afc.disconnect()
            throw InstallerError.afcFailed("Swift AFC: \(error)")
        }

        // 4. 連接 lockdownd（供 installation_proxy 用）
        progress("連接設備...", 81)
        let lockdown = LockdownClient(host: host)
        try await lockdown.connect(pairingFileURL: pairingURL)
        defer { lockdown.disconnect() }
        progress("配對驗證通過", 82)

        // 5. 經 installation_proxy 安裝
        progress("開始安裝...", 82)
        let proxy = InstallationProxy(lockdown: lockdown)
        let proxyHost = try await proxy.connect()
        progress("安裝服務地址=\(proxyHost)", 82)
        defer { proxy.disconnect() }
        try await proxy.install(packagePath: installPath) { percent in
            progress("安裝中... \(percent)%", 82 + percent * 18 / 100)
        }

        progress("完成", 100)
    }

    private func findPairingFile() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("PairingFiles")
        let lockdownURL = dir.appendingPathComponent("PairingFile_Lockdown.plist")
        if FileManager.default.fileExists(atPath: lockdownURL.path) {
            return lockdownURL
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            return files.first(where: { $0.pathExtension == "plist" })
        }
        return nil
    }

public enum InstallerError: Error, LocalizedError {
    case vpnNotConnected
    case noPairingFile
    case afcFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .vpnNotConnected: return "VPN 未連接"
        case .noPairingFile: return "找不到配對檔"
        case .afcFailed(let msg): return msg
        }
    }
}
