import Foundation

@main
struct IPAAppBundleSelectorTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAAppBundleSelectorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        do {
            _ = try IPAAppBundleSelector.select(in: payload)
            fatalError("Accepted an IPA with no root-level app bundle")
        } catch IPAAppBundleSelectionError.notFound { }

        let fixture = payload.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let selected = try IPAAppBundleSelector.select(in: payload)
        precondition(selected.standardizedFileURL == fixture.standardizedFileURL)

        let misleadingFile = payload.appendingPathComponent("NotAnApp.app")
        try Data().write(to: misleadingFile)
        let selectedWithFile = try IPAAppBundleSelector.select(in: payload)
        precondition(selectedWithFile.standardizedFileURL == fixture.standardizedFileURL)

        let second = payload.appendingPathComponent("Second.app", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        do {
            _ = try IPAAppBundleSelector.select(in: payload)
            fatalError("Silently selected one of multiple root-level app bundles")
        } catch IPAAppBundleSelectionError.ambiguous(let names) {
            precondition(names == ["Fixture.app", "Second.app"])
        }

        print("IPAAppBundleSelectorTests: PASS (missing, unique, non-directory and ambiguous candidates)")
    }
}
