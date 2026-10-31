import Foundation

/// Remote paths for a whole-IPA transfer through AFC's shared staging root.
struct IPAStagingPaths: Equatable {
    let uploadPath: String
    let installationPath: String

    init(identifier: UUID) {
        let filename = "\(identifier.uuidString).ipa"
        uploadPath = "/PublicStaging/\(filename)"
        installationPath = "PublicStaging/\(filename)"
    }
}
