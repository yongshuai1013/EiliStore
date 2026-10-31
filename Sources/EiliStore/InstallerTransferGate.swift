import Foundation

/// Guarantees that installation cannot begin unless all remote staging and upload work succeeds.
enum InstallerTransferGate {
    static func run(
        transfer: () async throws -> Void,
        installation: () async throws -> Void
    ) async throws {
        try await transfer()
        try await installation()
    }
}
