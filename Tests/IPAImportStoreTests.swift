import Foundation

@main
struct IPAImportStoreTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("IPAImportStoreTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("staged", isDirectory: true)
        let inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError("FAIL: \(message)") }
        }
        func bytes(_ name: String, _ data: [UInt8]) throws -> URL {
            let url = inputs.appendingPathComponent(name)
            try Data(data).write(to: url)
            return url
        }
        func mustThrow(_ url: URL, _ label: String) throws {
            do { _ = try IPAImportStore.stage(url, rootDirectory: root); fatalError("Expected rejection: \(label)") }
            catch is IPAImportStore.ImportError { }
        }

        let source = try bytes("same.ipa", [0, 1, 2, 3, 4])
        let first = try IPAImportStore.stage(source, rootDirectory: root)
        let second = try IPAImportStore.stage(source, rootDirectory: root)
        check(first.id != second.id && first.url != second.url, "same-name imports are isolated")
        check(first.originalFilename == "same.ipa", "original filename retained")
        let initialStagedBytes = try Data(contentsOf: first.url)
        check(initialStagedBytes == Data([0, 1, 2, 3, 4]), "staged bytes match")
        try Data([9, 8]).write(to: source)
        let copiedStagedBytes = try Data(contentsOf: first.url)
        check(copiedStagedBytes == Data([0, 1, 2, 3, 4]), "copy is independent")

        let upper = try bytes("UPPER.IPA", [5])
        let upperImported = try IPAImportStore.stage(upper, rootDirectory: root)
        check(upperImported.originalFilename == "UPPER.IPA", "uppercase extension accepted")
        try mustThrow(try bytes("bad.zip", [1]), "extension")
        let empty = try bytes("empty.ipa", [])
        try mustThrow(empty, "empty file")
        let directory = inputs.appendingPathComponent("folder.ipa", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try mustThrow(directory, "directory")
        #if !os(Windows)
        let link = inputs.appendingPathComponent("link.ipa")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        try mustThrow(link, "symlink")
        #endif
        let nonFile = URL(string: "https://example.com/file.ipa")!
        try mustThrow(nonFile, "non-file URL")

        IPAImportStore.remove(first)
        check(!fm.fileExists(atPath: first.url.path), "remove deletes staged import")
        check(fm.fileExists(atPath: source.path), "remove never deletes source")
        check(fm.fileExists(atPath: second.url.path), "remove preserves other UUID import")
        IPAImportStore.remove(second)
        IPAImportStore.remove(upperImported)
        print("IPAImportStoreTests: PASS")
    }
}
