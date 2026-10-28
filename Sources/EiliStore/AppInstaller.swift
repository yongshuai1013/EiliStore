import Foundation
import ZIPFoundation

/// IPA 安裝時可選的傳輸／安裝模式。
public enum AppInstallationMode: String, CaseIterable, Identifiable, Equatable {
    /// 直接把 IPA 傳到裝置，交由 installation_proxy 安裝。
    case ipa
    /// 在本機解壓 IPA，只傳送其中的 .app bundle。
    case appBundle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ipa: return "整包 IPA"
        case .appBundle: return "解壓 .app"
        }
    }
}

/// App 安裝協調器（經外置 VPN）。
public class AppInstaller {
    public static let shared = AppInstaller()
    public static let installationModeDefaultsKey = "appInstallationMode"

    private init() {}

    public func install(
        ipaURL: URL,
        mode: AppInstallationMode? = nil,
        progress: @escaping (String, Int) -> Void
    ) async throws {
        RustFFILock.shared.isTransferActive = true
        defer { RustFFILock.shared.isTransferActive = false }

        // 進度節流：上傳回調以 64KB／每文件為單位高頻觸發，每次都送主執行緒更新 UI 與寫日誌，
        // 大包上傳時會把主執行緒塞滿（畫面卡頓，嚴重時被 watchdog 強殺）。只在百分比變化時才往外送。
        let progressGate = ProgressGate()
        let reportProgress: (String, Int) -> Void = { message, percent in
            guard progressGate.shouldEmit(percent: percent) else { return }
            progress(message, percent)
        }

        let storedMode = UserDefaults.standard.string(forKey: Self.installationModeDefaultsKey)
        let selectedMode = mode ?? storedMode.flatMap { AppInstallationMode(rawValue: $0) } ?? .ipa

        reportProgress("檢查 VPN 連線...", 0)
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else { throw InstallerError.vpnNotConnected }
        let host = VPNConnectionChecker.shared.effectiveGatewayHost

        reportProgress("讀取配對檔...", 5)
        guard let pairingURL = findPairingFile() else { throw InstallerError.noPairingFile }

        var extractionDirectory: URL?
        defer {
            if let extractionDirectory {
                try? FileManager.default.removeItem(at: extractionDirectory)
            }
        }

        let localPackageURL: URL
        let remoteUploadPath: String
        let remoteStagingDirectory: String?
        let remotePackagePath: String
        let packageType: InstallationPackageType

        switch selectedMode {
        case .ipa:
            let stagingName = UUID().uuidString
            localPackageURL = ipaURL
            remoteStagingDirectory = "/PublicStaging/\(stagingName)"
            remoteUploadPath = "/PublicStaging/\(stagingName)/app.ipa"
            remotePackagePath = "PublicStaging/\(stagingName)/app.ipa"
            packageType = .ipa

        case .appBundle:
            reportProgress("解壓 IPA...", 10)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            extractionDirectory = tempDir

            guard let archive = Archive(url: ipaURL, accessMode: .read) else {
                throw InstallerError.afcFailed("無法打開 IPA")
            }
            for entry in archive {
                let destination = tempDir.appendingPathComponent(entry.path)
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    _ = try archive.extract(entry, to: destination)
                }
            }

            let payloadDir = tempDir.appendingPathComponent("Payload", isDirectory: true)
            do {
                localPackageURL = try IPAAppBundleSelector.select(in: payloadDir)
            } catch {
                throw InstallerError.afcFailed(error.localizedDescription)
            }
            remoteUploadPath = "/PublicStaging/\(UUID().uuidString).app"
            remoteStagingDirectory = nil
            remotePackagePath = remoteUploadPath
            packageType = .developerApp
        }

        let afc = RustAFCClient(host: host, pairingFileURL: pairingURL)
        do {
            try await afc.connect()
            try await afc.makeDirectory("/PublicStaging")

            switch selectedMode {
            case .ipa:
                if let remoteStagingDirectory {
                    try await afc.makeDirectory(remoteStagingDirectory)
                }
                reportProgress("上傳整包 IPA...", 15)
                try await afc.uploadFile(localURL: localPackageURL, remotePath: remoteUploadPath) { sent, total in
                    let fraction = total > 0 ? Double(sent) / Double(total) : 1
                    let percent = min(75, 15 + Int(fraction * 60))
                    let sentMB = Double(sent) / 1_048_576
                    let totalMB = Double(total) / 1_048_576
                    reportProgress(String(format: "上傳 IPA：%.1f / %.1f MB", sentMB, totalMB), percent)
                }
            case .appBundle:
                try await uploadAppBundle(at: localPackageURL, remotePath: remoteUploadPath, using: afc, progress: reportProgress)
            }
            afc.disconnect()
        } catch {
            afc.disconnect()
            throw InstallerError.afcFailed("上傳失敗: \(error.localizedDescription)")
        }

        reportProgress("安裝...", 80)
        let installer = RustInstallationProxy(host: host, pairingFileURL: pairingURL)
        do {
            try await installer.connect()
            try await installer.install(packagePath: remotePackagePath, packageType: packageType) { message, percent in
                reportProgress(message, percent)
            }
            installer.disconnect()
        } catch {
            installer.disconnect()
            throw InstallerError.afcFailed("安裝失敗: \(error.localizedDescription)")
        }

        reportProgress("安裝完成", 100)
    }

    private func uploadAppBundle(
        at appLocalURL: URL,
        remotePath: String,
        using afc: RustAFCClient,
        progress: @escaping (String, Int) -> Void
    ) async throws {
        var directories: [String] = []
        var files: [(local: URL, remote: String)] = []
        if let enumerator = FileManager.default.enumerator(atPath: appLocalURL.path) {
            for case let relativePath as String in enumerator {
                let localPath = appLocalURL.appendingPathComponent(relativePath).path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory) {
                    let remote = remotePath + "/" + relativePath
                    if isDirectory.boolValue {
                        directories.append(remote)
                    } else {
                        files.append((local: URL(fileURLWithPath: localPath), remote: remote))
                    }
                }
            }
        }

        progress("上傳 \(appLocalURL.lastPathComponent)...", 15)
        progress("共 \(files.count) 個文件", 16)
        try await afc.makeDirectory(remotePath)
        for directory in directories {
            try await afc.makeDirectory(directory)
        }

        var done = 0
        for file in files {
            try await afc.uploadFile(localURL: file.local, remotePath: file.remote) { _, _ in }
            done += 1
            let percent = 15 + Int(Double(done) / Double(files.count) * 60.0)
            progress("上傳中 \(done)/\(files.count)", percent)
        }
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
        PairingFileStore.shared.selectedPairingFileURL()
    }
}

/// 執行緒安全的進度節流器：只放行百分比有變化的回報。
private final class ProgressGate {
    private let lock = NSLock()
    private var lastPercent = -1

    func shouldEmit(percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent != lastPercent else { return false }
        lastPercent = percent
        return true
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
        case .afcFailed(let message): return message
        }
    }
}
