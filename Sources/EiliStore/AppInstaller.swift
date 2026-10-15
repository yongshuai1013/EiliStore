import Foundation
import ZIPFoundation

/// App 安裝協調器（經外置 VPN）
/// 仿 SideInstaller：解壓 IPA，上傳 .app 文件夾，PackageType=Developer
public class AppInstaller {
    public static let shared = AppInstaller()
    
    private init() {}
    
    public func install(ipaURL: URL, progress: @escaping (String, Int) -> Void) async throws {
        RustFFILock.shared.isTransferActive = true
        defer { RustFFILock.shared.isTransferActive = false }
        
        progress("檢查 VPN 連線...", 0)
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else { throw InstallerError.vpnNotConnected }
        let host = VPNConnectionChecker.shared.effectiveGatewayHost
        
        progress("讀取配對檔...", 5)
        guard let pairingURL = findPairingFile() else { throw InstallerError.noPairingFile }
        
        // 解壓 IPA
        progress("解壓 IPA...", 10)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw InstallerError.afcFailed("無法打開 IPA")
        }
        for entry in archive {
            let dest = tempDir.appendingPathComponent(entry.path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: dest)
            }
        }
        
        let payloadDir = tempDir.appendingPathComponent("Payload")
        let contents = try FileManager.default.contentsOfDirectory(atPath: payloadDir.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw InstallerError.afcFailed("找不到 .app")
        }
        let appLocalURL = payloadDir.appendingPathComponent(appName)
        let remoteAppPath = "/PublicStaging/\(appName)"
        progress("上傳 \(appName)...", 15)
        
        // 收集文件
        var dirs: [String] = []
        var files: [(local: URL, remote: String)] = []
        if let enumerator = FileManager.default.enumerator(atPath: appLocalURL.path) {
            for case let rel as String in enumerator {
                let localPath = appLocalURL.appendingPathComponent(rel).path
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) {
                    let remote = remoteAppPath + "/" + rel
                    if isDir.boolValue {
                        dirs.append(remote)
                    } else {
                        files.append((local: URL(fileURLWithPath: localPath), remote: remote))
                    }
                }
            }
        }
        progress("共 \(files.count) 個文件", 16)
        
        // 上傳
        let afc = RustAFCClient(host: host, pairingFileURL: pairingURL)
        do {
            try await afc.connect()
            try await afc.makeDirectory("/PublicStaging")
            try await afc.makeDirectory(remoteAppPath)
            for d in dirs {
                try await afc.makeDirectory(d)
            }
            var done = 0
            for f in files {
                try await afc.uploadFile(localURL: f.local, remotePath: f.remote) { _, _ in }
                done += 1
                let pct = 15 + Int(Double(done) / Double(files.count) * 60.0)
                progress("上傳中 \(done)/\(files.count)", pct)
            }
            afc.disconnect()
        } catch {
            afc.disconnect()
            throw InstallerError.afcFailed("上傳失敗: \(error.localizedDescription)")
        }
        
        // 安裝
        progress("安裝...", 80)
        let installer = RustInstallationProxy(host: host, pairingFileURL: pairingURL)
        do {
            try await installer.connect()
            try await installer.install(packagePath: remoteAppPath) { msg, pct in
                progress(msg, pct)
            }
            installer.disconnect()
        } catch {
            installer.disconnect()
            throw InstallerError.afcFailed("安裝失敗: \(error.localizedDescription)")
        }
        
        progress("安裝完成", 100)
    }
    
    public func diagnoseAFC() async -> String {
        var lines: [String] = []
        lines.append("AFC 引擎: Rust FFI")
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else { return "VPN 未連接" }
        let host = VPNConnectionChecker.shared.effectiveGatewayHost
        lines.append("Host: \(host)")
        guard let pairingURL = findPairingFile() else {
            return lines.joined(separator: "\n") + "\n無配對檔"
        }
        let afc = RustAFCClient(host: host, pairingFileURL: pairingURL)
        do {
            try await afc.connect()
            lines.append("✅ AFC 連接成功")
            afc.disconnect()
        } catch {
            lines.append("❌ AFC 連接失敗: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
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
