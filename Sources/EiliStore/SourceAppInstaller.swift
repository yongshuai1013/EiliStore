import Foundation
import SwiftUI
import SideSign
import ZIPFoundation

/// 從軟體源下載、簽名、安裝 App（一條龍）
@MainActor
final class SourceAppInstaller: ObservableObject {
    static let shared = SourceAppInstaller()
    private init() {}

    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var progress: Double = 0  // 0~1，-1 表示不確定

    private let signingService = PaxSigningService.shared

    enum InstallError: LocalizedError {
        case invalidURL
        case notLoggedIn
        case noTeam
        case noCertificate
        case downloadFailed(String)
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "下載連結無效"
            case .notLoggedIn: return "請先在設定頁登入 Apple ID"
            case .noTeam: return "沒有可用的開發者 Team"
            case .noCertificate: return "沒有激活的證書，請先在簽名管理中激活一個證書"
            case .downloadFailed(let m): return "下載失敗: \(m)"
            case .signingFailed(let m): return "簽名失敗: \(m)"
            }
        }
    }

    /// 下載 → 簽名 → 安裝
    func install(_ app: SourceApp) async {
        guard !isWorking else { return }
        isWorking = true
        progress = -1
        defer { isWorking = false }

        do {
            // 1. 下載 IPA
            statusMessage = "正在下載 \(app.name)..."
            let ipaURL = try await downloadIPA(app)
            statusMessage = "下載完成，正在簽名..."

            // 2. 簽名
            let signedIPA = try await signIPA(at: ipaURL, appName: app.name)
            statusMessage = "簽名完成，正在安裝..."

            // 3. 安裝
            try await AppInstaller.shared.install(ipaURL: signedIPA) { msg, pct in
                Task { @MainActor in
                    self.statusMessage = msg
                    self.progress = Double(pct) / 100.0
                }
            }

            // 4. 登記到 App 列表
            registerInstalledApp(signedIPA: signedIPA, sourceApp: app)

            statusMessage = "✅ \(app.name) 安裝完成"
            progress = 1
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
            progress = 0
        }
    }

    // MARK: - 下載

    private func downloadIPA(_ app: SourceApp) async throws -> URL {
        guard let url = URL(string: app.downloadURL) else {
            throw InstallError.invalidURL
        }
        let downloader = DownloadDelegate()
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        downloader.onProgress = { [weak self] p in
            Task { @MainActor in
                self?.progress = p * 0.4  // 下載佔 40%
                self?.statusMessage = "正在下載 \(app.name)... \(Int(p * 100))%"
            }
        }
        do {
            let (tempURL, _) = try await session.download(from: url)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dest = docs.appendingPathComponent("\(app.bundleId).ipa")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            throw InstallError.downloadFailed(error.localizedDescription)
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var onProgress: ((Double) -> Void)?
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    // MARK: - 簽名（流程同 SigningFlowView）

    private func signIPA(at ipaURL: URL, appName: String) async throws -> URL {
        // 取 Team
        let teams: [SideSign.Team]
        do {
            teams = try await signingService.fetchTeams()
        } catch {
            throw InstallError.notLoggedIn
        }
        guard let team = teams.first else { throw InstallError.noTeam }

        // 取激活證書
        guard let keyStore = signingService.loadActiveCertificate() else {
            throw InstallError.noCertificate
        }

        // 解包
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.unzipItem(at: ipaURL, to: workDir)

        let payload = workDir.appendingPathComponent("Payload")
        let contents = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.signingFailed("找不到 .app")
        }

        // Bundle IDs
        let bundleIDs = extractBundleIDs(from: appURL)
        guard !bundleIDs.isEmpty else {
            throw InstallError.signingFailed("讀不到 Bundle ID")
        }

        // 為每個 Bundle ID 建 App ID、拿 profile
        var profiles: [SideSign.ProvisioningProfile] = []
        for (i, bundleID) in bundleIDs.enumerated() {
            await MainActor.run {
                self.progress = 0.4 + Double(i) / Double(bundleIDs.count) * 0.2
                self.statusMessage = "正在準備 \(bundleID)..."
            }
            let appID = try await signingService.findOrCreateAppID(
                bundleIdentifier: bundleID, name: bundleID, for: team)
            let profile = try await signingService.provisioningProfile(for: appID, team: team)
            profiles.append(profile)
        }

        // 嵌入 + 簽名
        try embedProfiles(profiles, into: appURL)
        await MainActor.run { self.statusMessage = "正在簽名..." }
        let signer = SideSign.AppBundleSigner(team: team, keyStore: keyStore)
        try await signer.signApp(at: appURL, provisioningProfiles: profiles)

        // 重打包
        let packagedIPA = try FileManager.default.zipAppBundle(at: appURL, compressionLevel: .none)
        let signedIPA = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(appURL.deletingPathExtension().lastPathComponent)-signed.ipa")
        try? FileManager.default.removeItem(at: signedIPA)
        try FileManager.default.moveItem(at: packagedIPA, to: signedIPA)

        await MainActor.run { self.progress = 0.7 }
        return signedIPA
    }

    private func extractBundleIDs(from appURL: URL) -> [String] {
        var ids: [String] = []
        let infoPlist = appURL.appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOf: infoPlist),
           let bid = dict["CFBundleIdentifier"] as? String {
            ids.append(bid)
        }
        let plugIns = appURL.appendingPathComponent("PlugIns")
        if let extensions = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) {
            for ext in extensions where ext.pathExtension == "appex" {
                let extPlist = ext.appendingPathComponent("Info.plist")
                if let dict = NSDictionary(contentsOf: extPlist),
                   let bid = dict["CFBundleIdentifier"] as? String {
                    ids.append(bid)
                }
            }
        }
        return ids
    }

    private func embedProfiles(_ profiles: [SideSign.ProvisioningProfile], into appURL: URL) throws {
        for profile in profiles {
            let target: URL
            if profile.bundleIdentifier == (NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String) {
                target = appURL
            } else {
                let plugIns = appURL.appendingPathComponent("PlugIns")
                guard let extensions = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) else { continue }
                guard let ext = extensions.first(where: { extURL in
                    let plist = extURL.appendingPathComponent("Info.plist")
                    return (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) == profile.bundleIdentifier
                }) else { continue }
                target = ext
            }
            let dest = target.appendingPathComponent("embedded.mobileprovision")
            try profile.data.write(to: dest)
        }
    }

    // MARK: - 登記

    private func registerInstalledApp(signedIPA: URL, sourceApp: SourceApp) {
        // 保存一份 IPA 供以後重簽
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let savedIPA = docs.appendingPathComponent("\(sourceApp.bundleId)-signed.ipa")
        try? FileManager.default.removeItem(at: savedIPA)
        try? FileManager.default.copyItem(at: signedIPA, to: savedIPA)

        // 解析 + 圖標
        var iconPath: String? = nil
        var displayName = sourceApp.name
        var profileExpirationDate: Date?
        if let info = try? IPAParser.parse(ipaURL: savedIPA) {
            displayName = info.name
            profileExpirationDate = info.expirationDate
            if let iconData = info.iconData, !iconData.isEmpty {
                let iconsDir = docs.appendingPathComponent("AppIcons")
                try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
                let iconFile = iconsDir.appendingPathComponent("\(sourceApp.bundleId).png")
                if (try? iconData.write(to: iconFile)) != nil {
                    iconPath = iconFile.path
                }
            }
        }

        let expiresDate = profileExpirationDate
            ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())
            ?? Date()
        if profileExpirationDate == nil {
            AppLogger.shared.log("⚠️ IPA 沒有可讀取的內嵌 profile 到期日，沿用 7 天預設")
        } else {
            AppLogger.shared.log("已讀取 profile 到期日: \(expiresDate)")
        }

        let newApp = InstalledApp(
            name: displayName,
            bundleId: sourceApp.bundleId,
            team: "未知",
            expiresDate: expiresDate,
            ipaPath: savedIPA.path,
            iconPath: iconPath
        )
        AppManager.shared.addApp(newApp)
    }
}
