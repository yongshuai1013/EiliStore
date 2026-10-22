import Foundation

enum ELFLibraryFixtures {
    static func write(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ADILibraryProfile.legacy.filenames.map { name in
            let data = ADIElfFixture.make(soname: name,
                needed: name == "libstoreservicescore.so" ? ["libCoreADI.so", "libc.so"] : ["libc.so"],
                exports: name == "libstoreservicescore.so" ? ADILibraryCompatibility.requiredEntryPoints.sorted() : [],
                imports: ["malloc", "free"])
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
    }
}
