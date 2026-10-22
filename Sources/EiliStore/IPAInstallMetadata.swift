import Foundation

/// Validates only plist metadata. It does not sign, provision or install an App.
struct IPAInstallMetadata: Sendable {
    let name: String
    let bundleId: String
    let version: String

    enum MetadataError: LocalizedError {
        case invalidBundleIdentifier
        var errorDescription: String? { "IPA 的 Bundle ID 缺失或格式無效。" }
    }

    init(plist: [String: Any], fallbackName: String) throws {
        guard let identifier = plist["CFBundleIdentifier"] as? String,
              identifier.utf8.count <= 255 else { throw MetadataError.invalidBundleIdentifier }
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { allowed.contains($0) } }) else {
            throw MetadataError.invalidBundleIdentifier
        }
        self.bundleId = identifier
        let candidates = [plist["CFBundleDisplayName"] as? String, plist["CFBundleName"] as? String, fallbackName]
        self.name = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "App"
        let suppliedVersion = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = suppliedVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
    }
}
