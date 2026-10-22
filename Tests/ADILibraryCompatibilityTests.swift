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
        let bad = ADILibraryCompatibility.inspect(profile: profile, metadata: all)
        precondition(bad.mismatchedSONAMEs == ["libCoreFP.so"] && bad.unsupportedRelocations == [1028] && bad.unsupportedDynamicTags == [36])
        all.removeValue(forKey: "libCoreFP.so")
        let missing = ADILibraryCompatibility.inspect(profile: profile, metadata: all)
        precondition(missing.missingFiles == ["libCoreFP.so"] && missing.missingDependencies == ["libCoreFP.so"])
        do { _ = try ADILibraryCompatibility.readLibrary(URL(string: "https://invalid.example/libCoreADI.so")!); fatalError("non-file URL accepted") } catch {}
        print("PASS: ADI library profiles, dependency closure, cross-library symbols and fail-closed modern ABI gate")
    }
}
