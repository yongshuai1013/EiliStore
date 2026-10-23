import Foundation

@main struct ADILibraryCompatibilityTests {
    static func main() throws {
        func metadata(_ name: String, needed: [String] = [], exports: [String] = [], imports: [String] = [], relocations: [UInt32] = [1027], tags: [UInt64] = [], types: [String: UInt8] = [:]) throws -> ADIELFMetadata {
            try ADIELFMetadata.parse(ADIElfFixture.make(soname: name, needed: needed, exports: exports, imports: imports, relocations: relocations, dynamicTags: tags, symbolTypes: types))
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
            precondition(result.missingDependencies == [dependency] && !result.hasStaticBlockers, "legacy missing dependency is informational: \(dependency)")
        }
        var unknownImportSet = legacySet
        unknownImportSet["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], imports: ["mystery_strong_import", "malloc"])
        let unknownImport = ADILibraryCompatibility.inspect(profile: legacy, metadata: unknownImportSet)
        precondition(unknownImport.unhandledImports == ["mystery_strong_import"] && !unknownImport.hasStaticBlockers)
        precondition(unknownImport.fallbackFunctionImports == ["mystery_strong_import"] && unknownImport.blockedDataImports.isEmpty)
        precondition(unknownImport.summary.contains("SideStore 相容函式 stub（回傳0；非實際 ABI 實作，未驗證登入）"))
        for (name, type): (String, UInt8) in [("unknown_notype", 0), ("unknown_func", 2), ("environ_func", 2)] {
            var set = legacySet
            set["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], imports: [name], types: [name: type])
            let result = ADILibraryCompatibility.inspect(profile: legacy, metadata: set)
            precondition(!result.hasStaticBlockers && result.fallbackFunctionImports == [name])
        }
        for (name, type): (String, UInt8) in [("tls", 6), ("section", 3), ("ifunc", 10)] {
            var set = legacySet
            set["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], imports: [name], types: [name: type])
            let result = ADILibraryCompatibility.inspect(profile: legacy, metadata: set)
            precondition(!result.hasStaticBlockers && result.blockedDataImports.isEmpty, "unsupported symbol type is diagnostic only: \(name)")
            precondition(result.unsupportedSymbolImports == (type == 6 ? [] : [name]))
            precondition(result.fallbackFunctionImports == [name] && result.fallbackDataImports.isEmpty)
        }
        for (name, type): (String, UInt8) in [("object", 1), ("malloc", 1), ("_ZTVMissing", 0),
                                            ("_ZTIMissing", 2), ("_ZTSMissing", 0), ("kCFMissing", 0),
                                            ("kAudioMissing", 0), ("OBJC_Missing", 0), ("environ", 0),
                                            ("__sF", 2), ("__stack_chk_guard", 0)] {
            var set = legacySet
            set["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], imports: [name], types: [name: type])
            let result = ADILibraryCompatibility.inspect(profile: legacy, metadata: set)
            precondition(!result.hasStaticBlockers && result.fallbackDataImports == [name] && result.fallbackFunctionImports.isEmpty, "ordinary data must get data fallback, not a function: \(name)")
        }
        for name in ["_ZTVknown", "kCFConstant", "OBJC_Class", "__sF"] {
            let objectMeta = ADIELFMetadata(needed: [], soname: "libCoreADI.so", exportedSymbols: Set(required), undefinedStrongSymbols: [name], relocationTypes: [1027], unsupportedDynamicTags: [], undefinedDataSymbols: [name])
            let objectResult = ADILibraryCompatibility.inspect(profile: legacy, metadata: ["libCoreADI.so": objectMeta, "libstoreservicescore.so": ADIELFMetadata(needed: [], soname: "libstoreservicescore.so", exportedSymbols: Set(required), undefinedStrongSymbols: [], relocationTypes: [1027], unsupportedDynamicTags: [])])
            precondition(!objectResult.hasStaticBlockers && objectResult.fallbackDataImports == [name] && objectResult.blockedDataImports.isEmpty)
        }
        let dataNames = (0..<40).map { "arbitrary_object_\($0)" }
        let manyFunctions = (0..<331).map { "unknown_func_\($0)" }
        let direct = ADIELFMetadata(needed: ["libmissingA.so", "libmissingB.so", "libmissingC.so"], soname: "libCoreADI.so", exportedSymbols: Set(required), undefinedStrongSymbols: Set(manyFunctions + dataNames), relocationTypes: [1027], unsupportedDynamicTags: [], undefinedFunctionSymbols: Set(manyFunctions), undefinedDataSymbols: Set(dataNames))
        let directResult = ADILibraryCompatibility.inspect(profile: legacy, metadata: ["libCoreADI.so": direct, "libstoreservicescore.so": ADIELFMetadata(needed: [], soname: "libstoreservicescore.so", exportedSymbols: Set(required), undefinedStrongSymbols: Set(manyFunctions + dataNames), relocationTypes: [1027], unsupportedDynamicTags: [], undefinedFunctionSymbols: Set(manyFunctions), undefinedDataSymbols: Set(dataNames))])
        precondition(directResult.fallbackFunctionImports.count == 331 && directResult.fallbackDataImports.count == 40 && directResult.blockedDataImports.isEmpty && !directResult.hasStaticBlockers)
        precondition(directResult.summary.contains("256-byte zero-filled") && directResult.summary.contains("非實際 ABI 實作"))
        var conflicting = legacySet
        conflicting["libCoreADI.so"] = try metadata("libCoreADI.so", exports: Array(required.prefix(3)), imports: ["conflict"], types: ["conflict": 2])
        conflicting["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)), imports: ["conflict"], types: ["conflict": 6])
        let conflict = ADILibraryCompatibility.inspect(profile: legacy, metadata: conflicting)
        precondition(!conflict.hasStaticBlockers && conflict.blockedDataImports.isEmpty)
        conflicting["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)), imports: ["conflict"], types: ["conflict": 1])
        let dataConflict = ADILibraryCompatibility.inspect(profile: legacy, metadata: conflicting)
        precondition(!dataConflict.hasStaticBlockers && dataConflict.blockedDataImports.isEmpty, "lookup conflict is resolved at runtime, not preflight-blocked")
        for type: UInt8 in [3, 6, 10] {
            var weakSet = legacySet
            weakSet["libCoreADI.so"] = try ADIELFMetadata.parse(ADIElfFixture.make(soname: "libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], weakImports: ["kCFUnsafe"], symbolTypes: ["kCFUnsafe": type]))
            weakSet["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)) + ["kCFUnsafe"])
            let result = ADILibraryCompatibility.inspect(profile: legacy, metadata: weakSet)
            precondition(!result.hasStaticBlockers && result.blockedDataImports.isEmpty, "weak imports use SideStore resolution semantics")
        }
        var weakFallback = legacySet
        weakFallback["libCoreADI.so"] = try ADIELFMetadata.parse(ADIElfFixture.make(soname: "libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"], weakImports: ["weak_func", "weak_object"], symbolTypes: ["weak_object": 1]))
        let weakReport = ADILibraryCompatibility.inspect(profile: legacy, metadata: weakFallback)
        precondition(!weakReport.hasStaticBlockers && weakReport.fallbackFunctionImports == ["weak_func"] && weakReport.fallbackDataImports == ["weak_object"])
        var tlsSegmentSet = legacySet
        var tlsSegmentBytes = ADIElfFixture.make(soname: "libCoreADI.so", exports: Array(required.prefix(3)) + ["cross_library_hook"])
        // Add a third zero-sized PT_TLS header without changing PT_LOAD/PT_DYNAMIC.
        tlsSegmentBytes[56] = 3; tlsSegmentBytes[176] = 7
        tlsSegmentSet["libCoreADI.so"] = try ADIELFMetadata.parse(tlsSegmentBytes)
        let tlsSegmentReport = ADILibraryCompatibility.inspect(profile: legacy, metadata: tlsSegmentSet)
        precondition(tlsSegmentReport.hasThreadLocalSegments && !tlsSegmentReport.hasStaticBlockers, "PT_TLS is reported, not preflight-blocked")

        // The two optional native entrypoints are not part of the six required entrypoints.
        let optionalMissing = ADILibraryCompatibility.inspect(profile: legacy, metadata: legacySet)
        precondition(!optionalMissing.hasStaticBlockers && !optionalMissing.missingEntryPoints.contains("n388H58b") && !optionalMissing.missingEntryPoints.contains("p435345l3"))
        var missingEntrySet = legacySet
        missingEntrySet["libstoreservicescore.so"] = try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(4)))
        let missingEntry = ADILibraryCompatibility.inspect(profile: legacy, metadata: missingEntrySet)
        precondition(missingEntry.missingEntryPoints == [required[3]])
        precondition(!missingEntry.hasStaticBlockers, "missing legacy entrypoint is diagnostic only")

        var badLegacy = legacySet
        badLegacy["libCoreADI.so"] = try metadata("wrongCoreADI.so", exports: Array(required.prefix(3)), relocations: [1027, 1028], tags: [36])
        let bad = ADILibraryCompatibility.inspect(profile: legacy, metadata: badLegacy)
        precondition(bad.mismatchedSONAMEs == ["libCoreADI.so"] && bad.unsupportedRelocations == [1028] && bad.unsupportedDynamicTags == [36] && !bad.hasStaticBlockers)
        let ignoredLegacyFormats = ADILibraryCompatibility.inspect(profile: legacy, metadata: [
            "libCoreADI.so": try metadata("libCoreADI.so", exports: Array(required.prefix(3)), relocations: [1027, 1028], tags: [36]),
            "libstoreservicescore.so": try metadata("libstoreservicescore.so", exports: Array(required.dropFirst(3)))
        ])
        precondition(ignoredLegacyFormats.unsupportedRelocations == [1028] && ignoredLegacyFormats.unsupportedDynamicTags == [36] && !ignoredLegacyFormats.hasStaticBlockers, "legacy ignored formats remain diagnostics")
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
        precondition(badModern.mismatchedSONAMEs == ["libCoreFP.so"] && badModern.unsupportedRelocations == [1028] && badModern.unsupportedDynamicTags == [36] && badModern.hasStaticBlockers)
        all.removeValue(forKey: "libCoreFP.so")
        let missing = ADILibraryCompatibility.inspect(profile: profile, metadata: all)
        precondition(missing.missingFiles == ["libCoreFP.so"] && missing.missingDependencies == ["libCoreFP.so"])
        do { _ = try ADILibraryCompatibility.readLibrary(URL(string: "https://invalid.example/libCoreADI.so")!); fatalError("non-file URL accepted") } catch {}
        print("PASS: synthetic legacy hooks, dependencies, entrypoints, aliases and modern compatibility gate")
    }
}
