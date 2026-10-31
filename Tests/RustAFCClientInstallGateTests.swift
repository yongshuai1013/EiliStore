import Foundation
import IDevice

@main
struct RustAFCClientInstallGateTests {
    static func main() async throws {
        let pairingURL = FileManager.default.temporaryDirectory.appendingPathComponent("unused-pairing-record")
        let client = RustAFCClient(host: "127.0.0.1", pairingFileURL: pairingURL)
        let identifier = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let ipaPaths = IPAStagingPaths(identifier: identifier)
        check(ipaPaths.uploadPath == "/PublicStaging/550E8400-E29B-41D4-A716-446655440000.ipa", "IPA upload path is a flat UUID file")
        check(ipaPaths.installationPath == "PublicStaging/550E8400-E29B-41D4-A716-446655440000.ipa", "installation path matches flat IPA file")
        try await client.connect()
        defer { client.disconnect() }

        test_afc_reset()
        test_afc_fail_next_directory(106, 16)
        try await client.makeDirectory("/already-exists")
        check(test_afc_directory_calls() == 1, "directory operation reached FFI")
        check(test_afc_error_free_calls() == 1, "ObjectExists FFI error freed")

        test_afc_reset()
        test_afc_fail_next_directory(106, 10)
        let permissionError = await captureError { try await client.makeDirectory("/denied") }
        check(permissionError != nil, "non-ObjectExists AFC error must fail")
        check(permissionError?.userInfo["ideviceCode"] as? Int32 == 106, "top-level FFI code preserved")
        check(permissionError?.userInfo["ideviceSubCode"] as? Int32 == 10, "AFC sub-code preserved")
        check(permissionError?.localizedDescription.contains("[106:10]") == true, "safe numeric error included")
        check(permissionError?.localizedDescription.contains("DO_NOT_EXPOSE") == false, "Rust debug payload not exposed")
        check(test_afc_error_free_calls() == 1, "failed directory FFI error freed")

        test_afc_reset()
        test_afc_fail_next_directory(33, 16)
        let wrongCategoryError = await captureError { try await client.makeDirectory("/not-afc-object-exists") }
        check(wrongCategoryError != nil, "matching sub-code in another category is not success")

        let localFile = FileManager.default.temporaryDirectory.appendingPathComponent("afc-open-failure-\(UUID().uuidString).ipa")
        try Data([1, 2, 3]).write(to: localFile)
        defer { try? FileManager.default.removeItem(at: localFile) }

        test_afc_reset()
        test_afc_fail_next_open(106, 8)
        let openError = await captureError {
            try await client.uploadFile(localURL: localFile, remotePath: "/staging/app.ipa") { _, _ in }
        }
        check(openError != nil, "remote file-open error must propagate")
        check(openError?.userInfo["ideviceCode"] as? Int32 == 106, "remote-open FFI code preserved")
        check(openError?.userInfo["ideviceSubCode"] as? Int32 == 8, "remote-open AFC sub-code preserved")
        check(openError?.localizedDescription.contains("DO_NOT_EXPOSE") == false, "remote-open Rust debug payload not exposed")
        check(test_afc_error_free_calls() == 1, "remote-open FFI error freed")

        try await verifyFailureSkipsInstallation(client: client, localFile: localFile, failDirectory: true)
        try await verifyFailureSkipsInstallation(client: client, localFile: localFile, failDirectory: false)

        test_afc_reset()
        var installationEntered = false
        try await InstallerTransferGate.run(transfer: {
            try await client.connect()
            do {
                try await client.makeDirectory("/PublicStaging")
                try await client.uploadFile(localURL: localFile, remotePath: ipaPaths.uploadPath) { _, _ in }
                client.disconnect()
            } catch {
                client.disconnect()
                throw error
            }
        }, installation: {
            installationEntered = true
        })
        check(installationEntered, "successful transfer enters installation")
        check(test_afc_directory_calls() == 1, "flat IPA staging only creates shared root")
        check(test_afc_open_calls() == 1, "successful remote open reached FFI")

        print("RustAFCClientInstallGateTests: PASS")
    }

    private static func verifyFailureSkipsInstallation(
        client: RustAFCClient,
        localFile: URL,
        failDirectory: Bool
    ) async throws {
        test_afc_reset()
        let ipaPaths = IPAStagingPaths(identifier: UUID())
        if failDirectory {
            test_afc_fail_next_directory(106, 10)
        } else {
            test_afc_fail_next_open(106, 8)
        }
        var installationEntered = false
        let error = await captureError {
            try await InstallerTransferGate.run(transfer: {
                try await client.connect()
                do {
                    try await client.makeDirectory("/PublicStaging")
                    try await client.uploadFile(localURL: localFile, remotePath: ipaPaths.uploadPath) { _, _ in }
                    client.disconnect()
                } catch {
                    client.disconnect()
                    throw error
                }
            }, installation: {
                installationEntered = true
            })
        }
        check(error != nil, failDirectory ? "directory failure propagates" : "remote-open failure propagates")
        check(!installationEntered, failDirectory ? "directory failure must skip installation" : "remote-open failure must skip installation")
        check(test_afc_error_free_calls() == 1, "failed FFI error released in transfer gate")
        check(test_afc_directory_calls() == 1, "IPA transfer never creates a UUID subdirectory")
        if failDirectory {
            check(test_afc_open_calls() == 0, "directory failure occurs before remote open")
        } else {
            check(test_afc_open_calls() == 1, "remote open attempted before transfer failure")
        }
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, "FAIL: \(message)")
    }

    private static func captureError(_ operation: () async throws -> Void) async -> NSError? {
        do {
            try await operation()
            return nil
        } catch {
            return error as NSError
        }
    }
}
