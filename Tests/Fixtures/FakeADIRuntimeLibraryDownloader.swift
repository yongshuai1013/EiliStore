import Foundation
/// Network-free service-test double; tests inject staging at the service boundary.
struct ADIRuntimeLibraryDownloader: Sendable {
    enum UnexpectedDownload: Error { case networkMustNotRun }
    init(metadataURL: URL, fallbackURL: URL?) {}
    func stageLibraries(in directory: URL) async throws -> [URL] {
        throw UnexpectedDownload.networkMustNotRun
    }
}
