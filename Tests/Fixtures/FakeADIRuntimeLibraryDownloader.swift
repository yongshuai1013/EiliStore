import Foundation

/// Service tests inject staging explicitly. Network/ZIP behavior has its own suite.
struct ADIRuntimeLibraryDownloader: Sendable {
    enum UnexpectedDownload: Error { case networkMustNotRun }
    func stageLibraries(in directory: URL) async throws -> [URL] {
        throw UnexpectedDownload.networkMustNotRun
    }
}
