import Foundation

@main
struct IPAInstallMetadataTests {
    static func main() throws {
        let info = try IPAInstallMetadata(plist: [
            "CFBundleIdentifier": "com.example.Test-App",
            "CFBundleDisplayName": " Test App ",
            "CFBundleShortVersionString": "2.3"
        ], fallbackName: "Fallback")
        precondition(info.name == "Test App" && info.bundleId == "com.example.Test-App" && info.version == "2.3")
        let fallback = try IPAInstallMetadata(plist: ["CFBundleIdentifier": "org.example.app", "CFBundleDisplayName": "  "], fallbackName: "Fallback")
        precondition(fallback.name == "Fallback" && fallback.version == "1.0")
        let invalid = ["", "unknown", "com..example", ".com.example", "com.example.", "../escape", "com/example.app", "com.example\\app", "com.example.*", "com.example_a", "com.example app", "com.測試", String(repeating: "a", count: 256) + ".app"]
        for value in invalid {
            do {
                _ = try IPAInstallMetadata(plist: ["CFBundleIdentifier": value], fallbackName: "App")
                fatalError("Accepted invalid Bundle ID: \(value)")
            } catch IPAInstallMetadata.MetadataError.invalidBundleIdentifier { }
        }
        do {
            _ = try IPAInstallMetadata(plist: [:], fallbackName: "App")
            fatalError("Accepted missing Bundle ID")
        } catch IPAInstallMetadata.MetadataError.invalidBundleIdentifier { }
        print("IPAInstallMetadataTests: PASS (valid metadata, fallbacks and 14 invalid/missing IDs)")
    }
}
