import Foundation

/// Mirrors SideStore's default parentID + extension suffix scheme before provisioning.
enum SigningBundleIdentifiers {
    enum PreparationError: LocalizedError {
        case invalidInfoPlist(URL)
        case invalidExtension(String, parent: String)
        case writeFailed(URL)

        var errorDescription: String? {
            switch self {
            case .invalidInfoPlist(let url):
                return "無法讀取 Bundle ID：\(url.lastPathComponent)"
            case .invalidExtension(let identifier, let parent):
                return "Extension Bundle ID '\(identifier)' 必須以 '\(parent).' 開頭"
            case .writeFailed(let url):
                return "無法寫入 Info.plist：\(url.lastPathComponent)"
            }
        }
    }

    static func matches(_ registeredIdentifier: String, _ requestedIdentifier: String) -> Bool {
        registeredIdentifier.lowercased() == requestedIdentifier.lowercased()
    }

    static func prepare(appURL: URL, teamIdentifier: String, customIdentifier: String,
                        registeredIdentifiers: [String] = []) throws -> [String] {
        let mainInfo = appURL.appendingPathComponent("Info.plist")
        var main = try readInfo(at: mainInfo)
        let original = main["CFBundleIdentifier"] as! String
        let custom = customIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve an explicit override, and do not append the same team twice on re-signing.
        let requestedParent = custom.isEmpty
            ? (original.lowercased().hasSuffix(".\(teamIdentifier.lowercased())")
                ? original : "\(original).\(teamIdentifier)")
            : custom
        func registeredIdentifier(for requested: String) -> String {
            registeredIdentifiers.first { matches($0, requested) } ?? requested
        }
        let parent = registeredIdentifier(for: requestedParent)

        var identifiers = [parent]
        var updates: [(URL, [String: Any])] = []
        main["CFBundleIdentifier"] = parent
        updates.append((mainInfo, main))

        let plugins = appURL.appendingPathComponent("PlugIns")
        if FileManager.default.fileExists(atPath: plugins.path) {
            let extensions = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "appex" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for extensionURL in extensions {
                let infoURL = extensionURL.appendingPathComponent("Info.plist")
                var info = try readInfo(at: infoURL)
                let identifier = info["CFBundleIdentifier"] as! String
                guard identifier.hasPrefix(original + ".") else {
                    throw PreparationError.invalidExtension(identifier, parent: original)
                }
                let updated = registeredIdentifier(for: parent + String(identifier.dropFirst(original.count)))
                info["CFBundleIdentifier"] = updated
                identifiers.append(updated)
                updates.append((infoURL, info))
            }
        }

        // Validate every extension before modifying the extracted IPA. The source IPA is untouched.
        for (url, info) in updates {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw PreparationError.writeFailed(url)
            }
        }
        return identifiers
    }

    private static func readInfo(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw PreparationError.invalidInfoPlist(url)
        }
        return info
    }
}
