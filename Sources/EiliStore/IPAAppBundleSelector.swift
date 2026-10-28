import Foundation

enum IPAAppBundleSelectionError: LocalizedError {
    case notFound
    case ambiguous([String])

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "找不到 .app"
        case .ambiguous(let names):
            return "Payload 根目錄有多個 .app（\(names.joined(separator: "、"))），無法安全選擇"
        }
    }
}

enum IPAAppBundleSelector {
    static func select(in payloadDirectory: URL, fileManager: FileManager = .default) throws -> URL {
        let entries = try fileManager.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let apps = entries.filter { entry in
            guard entry.pathExtension == "app" else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        switch apps.count {
        case 0:
            throw IPAAppBundleSelectionError.notFound
        case 1:
            return apps[0]
        default:
            throw IPAAppBundleSelectionError.ambiguous(apps.map(\.lastPathComponent))
        }
    }
}
