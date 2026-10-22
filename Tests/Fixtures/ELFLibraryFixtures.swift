import Foundation

enum ELFLibraryFixtures {
    static func write(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["libCoreADI.so", "libstoreservicescore.so"]
        return try names.enumerated().map { index, name in
            var bytes = [UInt8](repeating: 0, count: 128)
            bytes[0...3] = [0x7f, 0x45, 0x4c, 0x46]
            bytes[4] = 2; bytes[5] = 1; bytes[6] = 1
            bytes[16] = 3; bytes[18] = 183
            bytes[64] = UInt8(index + 1)
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return url
        }
    }
}
