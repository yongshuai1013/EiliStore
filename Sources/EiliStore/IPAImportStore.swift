import Foundation

struct ImportedIPAFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let originalFilename: String
}

enum IPAImportStore {
    enum ImportError: LocalizedError {
        case invalidURL
        case invalidExtension
        case notRegularFile
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "來源必須是本機檔案 URL。"
            case .invalidExtension: return "只接受副檔名為 .ipa 的檔案。"
            case .notRegularFile: return "來源必須是一般檔案，不能是目錄或符號連結。"
            case .emptyFile: return "IPA 檔案不可為空。"
            }
        }
    }

    static func stage(
        _ sourceURL: URL,
        rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("EiliImportedIPAs", isDirectory: true)
    ) throws -> ImportedIPAFile {
        guard sourceURL.isFileURL else { throw ImportError.invalidURL }
        guard sourceURL.pathExtension.lowercased() == "ipa" else { throw ImportError.invalidExtension }

        #if canImport(Darwin)
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        #endif

        let manager = FileManager.default
        let values = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ImportError.notRegularFile }
        guard (values.fileSize ?? 0) > 0 else { throw ImportError.emptyFile }

        let id = UUID()
        let stagingDirectory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            let stagedURL = stagingDirectory.appendingPathComponent("import.ipa", isDirectory: false)
            try manager.copyItem(at: sourceURL, to: stagedURL)
            return ImportedIPAFile(id: id, url: stagedURL, originalFilename: sourceURL.lastPathComponent)
        } catch {
            try? manager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    static func remove(_ file: ImportedIPAFile) {
        // Delete only the UUID-scoped staging directory, never the source URL.
        let stagingDirectory = file.url.deletingLastPathComponent()
        guard stagingDirectory.lastPathComponent == file.id.uuidString,
              file.url.lastPathComponent == "import.ipa" else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}
