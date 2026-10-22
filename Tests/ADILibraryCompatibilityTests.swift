import Foundation

@main struct ADILibraryCompatibilityTests {
    static func main() throws {
        func metadata(_ name: String, needed: [String] = [], exports: [String] = [], imports: [String] = [], relocations: [UInt32] = [1027], tags: [UInt64] = []) throws -> ADIELFMetadata {
            try ADIELFMetadata.parse(ADIElfFixture.make(soname: name, needed: needed, exports: exports, imports: imports, relocations: relocations, dynamicTags: tags))
        }
        let profile = ADILibraryProfile.modern
        precondition(ADILibraryProfile.selected(profile.filenames) == .modern)
        precondition(ADILibraryProfile.selected(ADILibraryProfile.legacy.filenames) == .legacy)
        precondition(ADILibraryProfile.selected(Array(profile.filenames.dropLast())) == nil)
        precondition(ADILibraryProfile.selected(profile.filenames + [profile.filenames[0]]) == nil)
        precondition(ADILibraryProfile.selected(profile.filenames + ["libstoreservicescore.so"]) == nil)

        // Compact synthetic metadata: deliberately short symbol sets avoid fixture fixed-offset overlap.
        let legacy = ADILibraryProfile.legacy
        let required = ADILibraryCompatibility.requiredEntryPoints.sorted()
        let hooks = ADILibraryCompatibility.handledImports.sorted()
        var legacySet: [String: ADIELFMetadata] = [:]
        legacySet["libCoreADI.so"] = try metadata("libCoreADI.so", needed: ["libstoreservicescore.so", "libc.so"], exports: Array(required.prefix(3)) + ["cross_library_hook"], imports: ["cross_library_peer"])
        legacySet["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", needed: ["libCoreADI.so"], exports: Array(required.dropFirst(3)) + ["cross_library_peer"], imports: ["cross_library_hook"])
        let legacyComplete = ADILibraryCompatibility.inspect(profile: legacy, metadata: legacySet)
        precondition(!legacyComplete.hasStaticBlockers, "legacy known hooks and cross-library exports should resolve")
        for hook in hooks {
            let oneHook = try metadata("libCoreADI.so", exports: Array(required.prefix(3)), imports: [hook])
            let hookPeer = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)))
            precondition(ADILibraryCompatibility.inspect(profile: legacy, metadata: ["libCoreADI.so": oneHook, "libstoreservicescore.so": hookPeer]).unhandledImports.isEmpty, "known hook should resolve: \(hook)")
        }
        let mallocFixture = try metadata("libCoreADI.so", exports: Array(required.prefix(3)), imports: ["malloc"])
        let mallocPeer = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)))
        precondition(ADILibraryCompatibility.inspect(profile: legacy, metadata: ["libCoreADI.so": mallocFixture, "libstoreservicescore.so": mallocPeer]).unhandledImports.isEmpty, "malloc is explicitly supported")
        precondition(legacyComplete.runtimeAdapterAvailable)

        for dependency in ["libmediaplatform.so", "libCoreFoundation.so", "libc++_shared.so"] {
            var missingDependencySet = legacySet
            missingDependencySet["libCoreADI.so"] = try metadata("libCoreADI.so", needed: [dependency], exports: Array(required.prefix(3)))
            let result = ADILibraryCompatibility.inspect(profile: legacy, metadata: missingDependencySet)
            precondition(result.missingDependencies == [dependency] && result.hasStaticBlockers, "missing dependency must block: \(dependency)")
        }
        var unknownImportSet = legacySet
        unknownImportSet["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], imports: ["mystery_strong_import", "malloc"])
        let unknownImport = ADILibraryCompatibility.inspect(profile: legacy, metadata: unknownImportSet)
        precondition(unknownImport.unhandledImports == ["mystery_strong_import"] && unknownImport.hasStaticBlockers)

        // The two optional native entrypoints are not part of the six required entrypoints.
        let optionalMissing = ADILibraryCompatibility.inspect(profile: legacy, metadata: legacySet)
        precondition(!optionalMissing.hasStaticBlockers && !optionalMissing.missingEntryPoints.contains("n388H58b") && !optionalMissing.missingEntryPoints.contains("p435345l3"))
        var missingEntrySet = legacySet
        missingEntrySet["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(4)))
        let missingEntry = ADILibraryCompatibility.inspect(profile: legacy, metadata: missingEntrySet)
        precondition(missingEntry.missingEntryPoints == [required[3]])
        precondition(missingEntry.hasStaticBlockers, "missing required entrypoint must block")

        var badLegacy = legacySet
        badLegacy["libCoreADI.so"] = try metadata("wrongCoreADI.so", exports: Array(required.prefix(3)), relocations: [1027, 1028], tags: [36])
        let bad = ADILibraryCompatibility.inspect(profile: legacy, metadata: badLegacy)
        precondition(bad.mismatchedSONAMEs == ["libCoreADI.so"] && bad.unsupportedRelocations == [1028] && bad.unsupportedDynamicTags == [36] && bad.hasStaticBlockers)
        let noSONAME = ADIELFMetadata(needed: [], soname: nil, exportedSymbols: Set(required), undefinedStrongSymbols: [], relocationTypes: [1027], unsupportedDynamicTags: [])
        let noSONAMEResult = ADILibraryCompatibility.inspect(profile: legacy, metadata: ["libCoreADI.so": noSONAME, "libstoreservicescore.so": try metadata("libstoreservicescore.so", exports: [])])
        precondition(noSONAMEResult.mismatchedSONAMEs.isEmpty, "missing SONAME is allowed")

        // Accept only the loader's existing __ndk1 -> __1 spelling conversion, not arbitrary aliases.
        let aliasImport = "_Z3foo6__ndk1"
        let aliasExport = "_Z3foo3__1"
        var aliasSet: [String: ADIELFMetadata] = [:]
        aliasSet["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + [aliasExport], imports: [aliasImport])
        aliasSet["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)))
        precondition(ADILibraryCompatibility.inspect(profile: legacy, metadata: aliasSet).unhandledImports.isEmpty)
        aliasSet["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + ["_Z3foo3__2"], imports: [aliasImport])
        precondition(ADILibraryCompatibility.inspect(profile: legacy, metadata: aliasSet).unhandledImports == [aliasImport], "unrelated alias must not resolve")

        var all: [String: ADIELFMetadata] = [:]
        for name in profile.filenames { all[name] = try metadata(name) }
        all["libstoreapi.so"] = try metadata("libstoreapi.so", needed: Array(profile.filenames.dropLast()) + ["libc.so"], exports: ADILibraryCompatibility.requiredEntryPoints.sorted())
        let complete = ADILibraryCompatibility.inspect(profile: profile, metadata: all)
        precondition(!complete.hasStaticBlockers)
        precondition(!complete.runtimeAdapterAvailable, "metadata closure must not enable the unimplemented Android ABI")
        all["libCoreFP.so"] = try metadata("libCoreFP.so", imports: ["pthread_create", "malloc"])
        precondition(ADILibraryCompatibility.inspect(profile: profile, metadata: all).unhandledImports == ["pthread_create"])
        all["libCoreLSKD.so"] = try metadata("libCoreLSKD.so", exports: ["pthread_create"])
        precondition(ADILibraryCompatibility.inspect(profile: profile, metadata: all).unhandledImports.isEmpty)
        all["libCoreFP.so"] = try metadata("libCoreFP.so", needed: ["libnotprovided.so"])
        precondition(ADILibraryCompatibility.inspect(profile: profile, metadata: all).missingDependencies == ["libnotprovided.so"])
        all["libCoreFP.so"] = try metadata("libwrong.so", relocations: [1027, 1028], tags: [36])
        let badModern = ADILibraryCompatibility.inspect(profile: profile, metadata: all)
        precondition(badModern.mismatchedSONAMEs == ["libCoreFP.so"] && badModern.unsupportedRelocations == [1028] && badModern.unsupportedDynamicTags == [36])
        all.removeValue(forKey: "libCoreFP.so")
        let missing = ADILibraryCompatibility.inspect(profile: profile, metadata: all)
        precondition(missing.missingFiles == ["libCoreFP.so"] && missing.missingDependencies == ["libCoreFP.so"])
        do { _ = try ADILibraryCompatibility.readLibrary(URL(string: "https://invalid.example/libCoreADI.so")!); fatalError("non-file URL accepted") } catch {}
        print("PASS: synthetic legacy hooks, dependencies, entrypoints, aliases and modern compatibility gate")
    }
}
