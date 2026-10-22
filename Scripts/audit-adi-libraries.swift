import Foundation

@main struct AuditADILibraries {
    static func main() {
        do { try audit() }
        catch {
            FileHandle.standardError.write(Data("Static audit failed: malformed or unreadable ELF input.\n".utf8))
            exit(2)
        }
    }

    private static func audit() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: audit-adi-libraries.sh PRIVATE_LIBRARY_DIRECTORY\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let profile = ADILibraryProfile.detected(in: directory) else {
            FileHandle.standardError.write(Data("Ambiguous legacy/modern library names; do not mix or rename files.\n".utf8))
            exit(2)
        }
        let report = try ADILibraryCompatibility.read(directory: directory, profile: profile)
        var perLibrary: [String: Any] = [:]
        for name in profile.filenames {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let metadata = try ADIELFMetadata.parse(ADILibraryCompatibility.readLibrary(url))
                perLibrary[name] = ["soname": metadata.soname ?? "", "needed": metadata.needed,
                                    "export_count": metadata.exportedSymbols.count,
                                    "strong_import_count": metadata.undefinedStrongSymbols.count,
                                    "relocation_types": metadata.relocationTypes.sorted()]
            }
        }
        let output: [String: Any] = [
            "profile": profile.rawValue, "required_files": profile.filenames,
            "missing_files": report.missingFiles, "missing_dependencies": report.missingDependencies,
            "missing_required_ADI_exports": report.missingEntryPoints,
            "unhandled_strong_imports": report.unhandledImports,
            "unhandled_strong_import_count": report.unhandledImports.count,
            "unsupported_relocations": report.unsupportedRelocations,
            "unsupported_dynamic_tags": report.unsupportedDynamicTags,
            "mismatched_sonames": report.mismatchedSONAMEs,
            "has_known_static_blockers": report.hasStaticBlockers,
            "runtime_adapter_available": report.runtimeAdapterAvailable,
            "runtime_verified": false, "libraries": perLibrary,
            "summary": report.summary,
            "note": "Only static metadata was read. No Apple code, VM, provisioning, account, signing or network operations were executed. Explicit emulator hooks are not proof of correct ABI semantics."
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        if report.hasStaticBlockers || !report.runtimeAdapterAvailable { exit(1) }
    }
}
