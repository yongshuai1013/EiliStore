import Foundation

@main
struct SigningBundleIdentifiersTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description)
            passed += 1
        }
        func writeInfo(_ url: URL, _ identifier: String) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleDisplayName": "Fixture",
                "UnrelatedValue": ["keep": true]
            ], format: .binary, options: 0)
            try data.write(to: url.appendingPathComponent("Info.plist"))
        }
        func readInfo(_ url: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
        }
        func fixture(_ name: String, main: String = "com.kdt.livecontainer", extensions: [String]) throws -> URL {
            let app = root.appendingPathComponent(name + ".app")
            try writeInfo(app, main)
            for (index, identifier) in extensions.enumerated() {
                try writeInfo(app.appendingPathComponent("PlugIns/Extension\(index).appex"), identifier)
            }
            return app
        }
        let original = "com.kdt.livecontainer"
        let suffixes = [".LiveProcess", ".LiveWidget", ".ShareExtension", ".LaunchAppExtension"]
        let app = try fixture("LiveContainer", extensions: suffixes.map { original + $0 })
        let ids = try SigningBundleIdentifiers.prepare(appURL: app, teamIdentifier: "TESTTEAM01", customIdentifier: "")
        let parent = original + ".TESTTEAM01"
        check(ids == [parent] + suffixes.map { parent + $0 }, "Team suffix belongs before each extension suffix")
        check(try readInfo(app)["CFBundleIdentifier"] as? String == parent, "Main plist matches profile ID")
        check(try readInfo(app)["CFBundleDisplayName"] as? String == "Fixture", "Unrelated plist keys survive")
        for (index, suffix) in suffixes.enumerated() {
            let ext = app.appendingPathComponent("PlugIns/Extension\(index).appex")
            check(try readInfo(ext)["CFBundleIdentifier"] as? String == parent + suffix, "Extension plist matches profile ID")
        }
        let resigned = try SigningBundleIdentifiers.prepare(appURL: app, teamIdentifier: "TESTTEAM01", customIdentifier: "")
        check(resigned == ids, "Re-signing does not append the same Team ID twice")
        let overridden = try SigningBundleIdentifiers.prepare(appURL: app, teamIdentifier: "TESTTEAM01", customIdentifier: "  org.example.custom\n")
        check(overridden == ["org.example.custom"] + suffixes.map { "org.example.custom" + $0 }, "Custom ID remains exact and keeps extension suffixes")

        let caseApp = try fixture("Case", extensions: [original + ".LiveWidget"])
        let canonicalParent = "COM.KDT.LiveContainer.TESTTEAM01"
        let canonicalExtension = canonicalParent + ".LIVEWIDGET"
        let canonical = try SigningBundleIdentifiers.prepare(appURL: caseApp, teamIdentifier: "TESTTEAM01", customIdentifier: "",
            registeredIdentifiers: [original, canonicalParent, canonicalExtension])
        check(canonical == [canonicalParent, canonicalExtension], "Reuse only exact case-insensitive Team-scoped IDs, not original ID")
        check(try readInfo(caseApp)["CFBundleIdentifier"] as? String == canonicalParent, "Canonical portal casing is written for signer")
        check(SigningBundleIdentifiers.matches("Com.Test", "com.test"), "App ID reuse ignores case")
        check(!SigningBundleIdentifiers.matches("com.test.extra", "com.test"), "App ID reuse requires full match")

        let noExtensions = try fixture("NoExtensions", extensions: [])
        check(try SigningBundleIdentifiers.prepare(appURL: noExtensions, teamIdentifier: "TEAM2", customIdentifier: " \n") == [original + ".TEAM2"], "Whitespace override means automatic ID; no PlugIns is valid")

        let invalid = try fixture("InvalidExtension", extensions: [original + ".Good", original + "Extra.Bad"])
        do {
            _ = try SigningBundleIdentifiers.prepare(appURL: invalid, teamIdentifier: "TEAM2", customIdentifier: "")
            preconditionFailure("Invalid extension prefix must be rejected")
        } catch SigningBundleIdentifiers.PreparationError.invalidExtension {
            passed += 1
        }
        check(try readInfo(invalid)["CFBundleIdentifier"] as? String == original, "Validation failure does not modify main plist")
        check(try readInfo(invalid.appendingPathComponent("PlugIns/Extension0.appex"))["CFBundleIdentifier"] as? String == original + ".Good", "Validation failure does not modify earlier extensions")

        let missing = try fixture("MissingInfo", extensions: [original + ".Widget"])
        try fm.removeItem(at: missing.appendingPathComponent("PlugIns/Extension0.appex/Info.plist"))
        do {
            _ = try SigningBundleIdentifiers.prepare(appURL: missing, teamIdentifier: "TEAM2", customIdentifier: "")
            preconditionFailure("Missing extension plist must be rejected")
        } catch SigningBundleIdentifiers.PreparationError.invalidInfoPlist {
            passed += 1
        }
        check(try readInfo(missing)["CFBundleIdentifier"] as? String == original, "Missing plist failure does not modify main")
        print("SigningBundleIdentifiers: \(passed) checks passed (synthetic fixtures; no Apple requests).")
    }
}
