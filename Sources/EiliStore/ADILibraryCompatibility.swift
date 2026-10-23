import Foundation

enum ADILibraryProfile: String, Equatable, Sendable {
    case legacy, modern

    var filenames: [String] {
        switch self {
        case .legacy: return ["libCoreADI.so", "libstoreservicescore.so"]
        case .modern: return ["libCoreADI.so", "libCoreFP.so", "libCoreLSKD.so", "libFPDIFor3P.so", "libstoreapi.so"]
        }
    }

    static func selected(_ names: [String]) -> Self? {
        guard Set(names).count == names.count else { return nil }
        return [Self.legacy, .modern].first { Set($0.filenames) == Set(names) }
    }

    static func detected(in directory: URL) -> Self? {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let modern = !names.isDisjoint(with: Set(Self.modern.filenames).subtracting(Self.legacy.filenames))
        if modern && names.contains("libstoreservicescore.so") { return nil }
        return modern ? .modern : .legacy
    }
}

struct ADILibraryCompatibility: Equatable, Sendable {
    let profile: ADILibraryProfile
    let missingFiles: [String]
    let missingDependencies: [String]
    let missingEntryPoints: [String]
    let unhandledImports: [String]
    let fallbackFunctionImports: [String]
    let fallbackDataImports: [String]
    let unsupportedSymbolImports: [String]
    let blockedDataImports: [String]
    let unsupportedRelocations: [UInt32]
    let unsupportedDynamicTags: [UInt64]
    let hasThreadLocalSegments: Bool
    let mismatchedSONAMEs: [String]

    // This is an explicit capability gate, not a claim that static linking proves runtime safety.
    // libstoreapi requires a new Android ABI adapter; do not send it into the legacy loader.
    var runtimeAdapterAvailable: Bool { profile == .legacy }
    var hasStaticBlockers: Bool {
        !missingFiles.isEmpty || (profile == .modern && !missingDependencies.isEmpty) || !missingEntryPoints.isEmpty ||
        !blockedDataImports.isEmpty ||
        (profile == .modern && (!unsupportedRelocations.isEmpty || !unsupportedDynamicTags.isEmpty || hasThreadLocalSegments)) ||
        !mismatchedSONAMEs.isEmpty
    }
    var summary: String {
        var parts: [String] = []
        if !runtimeAdapterAvailable { parts.append("已識別新版 libstoreapi 庫組，但目前引擎尚未支援其 Android ABI") }
        if !missingFiles.isEmpty { parts.append("缺少 \(missingFiles.joined(separator: ", "))") }
        if !missingDependencies.isEmpty { parts.append(profile == .legacy ? "提示：另有 \(missingDependencies.count) 個未提供的相依庫（非靜態阻礙）" : "另有 \(missingDependencies.count) 個未提供的相依庫") }
        if !missingEntryPoints.isEmpty { parts.append("缺少 \(missingEntryPoints.count) 個必要 ADI 入口") }
        if !unhandledImports.isEmpty { parts.append("\(unhandledImports.count) 個外部符號尚無明確實作") }
        if !fallbackFunctionImports.isEmpty { parts.append("SideStore 相容函式 stub（回傳0；非實際 ABI 實作，未驗證登入）：\(fallbackFunctionImports.count) 個") }
        if !fallbackDataImports.isEmpty { parts.append("SideStore 相容資料 placeholder（256-byte zero-filled；非實際 ABI 實作，未驗證登入）：\(fallbackDataImports.count) 個") }
        if !unsupportedSymbolImports.isEmpty { parts.append("含尚未支援的 ELF 符號類型：\(unsupportedSymbolImports.count) 個") }
        if !blockedDataImports.isEmpty { parts.append("\(blockedDataImports.count) 個資料/TLS 外部符號無法安全 stub") }
        if !unsupportedRelocations.isEmpty { parts.append(profile == .legacy ? "\(unsupportedRelocations.count) 種重定位依 SideStore 略過（非實際 ABI/TLS 支援）" : "\(unsupportedRelocations.count) 種重定位尚未支援") }
        if !unsupportedDynamicTags.isEmpty { parts.append(profile == .legacy ? "提示：含載入器未實作的動態連結格式（不另行阻擋，不保證可運作）" : "含尚未支援的動態連結格式") }
        if hasThreadLocalSegments { parts.append(profile == .legacy ? "提示：PT_TLS 依 SideStore 不額外阻擋，但未實作執行緒 TLS" : "含尚未支援的 PT_TLS 執行緒區段") }
        if !mismatchedSONAMEs.isEmpty { parts.append("函式庫內部名稱與檔名不符，請勿改名混用") }
        if parts.isEmpty { parts.append("靜態檢查未發現已知阻礙，但不代表實際登入已驗證") }
        return parts.joined(separator: "；") + "。未啟動本機引擎，遠端預設不變。"
    }

    static let systemLibraries: Set<String> = ["libc.so", "libdl.so", "liblog.so", "libm.so", "libz.so", "libstdc++.so", "libandroid.so"]
    static func isSideStoreDataName(_ n: String) -> Bool {
        ["_ZTV", "_ZTI", "_ZTS", "kCF", "kAudio", "OBJC_"].contains { n.hasPrefix($0) } ||
            ["__CFConstantStringClassReference", "__sF", "environ", "__stack_chk_guard", "__ctype_"].contains(n)
    }
    static let requiredEntryPoints: Set<String> = ["Sph98paBcz", "nf92ngaK92", "kq56gsgHG6", "qi864985u0", "rsegvyrt87", "uv5t6nhkui"]
    // Only explicit router/adapter implementations count; this is not complete Android ABI support.
    static let handledImports: Set<String> = [
        "__android_log_print",
        "__cxa_allocate_exception",
        "__cxa_begin_catch",
        "__cxa_guard_acquire",
        "__cxa_guard_release",
        "__dynamic_cast",
        "__errno",
        "__errno_location",
        "__memchr_chk",
        "__system_property_get",
        "arc4random",
        "atof",
        "atoi",
        "atoll",
        "calloc",
        "chmod",
        "close",
        "dl_iterate_phdr",
        "dlclose",
        "dlerror",
        "dlopen",
        "dlsym",
        "free",
        "fstat",
        "ftruncate",
        "getauxval",
        "gettimeofday",
        "lstat",
        "malloc",
        "memchr",
        "memcmp",
        "memcpy",
        "memmem",
        "memmove",
        "memset",
        "mkdir",
        "open",
        "pthread_mutex_destroy",
        "pthread_mutex_init",
        "pthread_mutex_lock",
        "pthread_mutex_trylock",
        "pthread_mutex_unlock",
        "pthread_rwlock_destroy",
        "pthread_rwlock_init",
        "pthread_rwlock_rdlock",
        "pthread_rwlock_tryrdlock",
        "pthread_rwlock_trywrlock",
        "pthread_rwlock_unlock",
        "pthread_rwlock_wrlock",
        "read",
        "realloc",
        "strcat",
        "strchr",
        "strcmp",
        "strcpy",
        "strcspn",
        "strlen",
        "strncat",
        "strncmp",
        "strncpy",
        "strnlen",
        "strpbrk",
        "strrchr",
        "strspn",
        "strstr",
        "strtod",
        "strtol",
        "strtoll",
        "strtoull",
        "umask",
        "write",
    ]

    static func inspect(profile: ADILibraryProfile, metadata: [String: ADIELFMetadata]) -> Self {
        let provided = Set(metadata.keys)
        let exports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.exportedSymbols) }
        let functionImports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.undefinedFunctionSymbols) }
        let dataImports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.undefinedDataSymbols) }
        let tlsImports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.undefinedTLSSymbols) }
        let unsupportedImports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.undefinedUnsupportedSymbols) }
        // Include weak imports: SideStore routes them through the same fallback.
        let imports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.undefinedStrongSymbols) }
            .union(functionImports).union(dataImports).union(tlsImports).union(unsupportedImports)
        // SideStore's legacy resolver uses exported symbols first; unresolved type-1
        // and named data heuristics get zero-filled storage, everything else a zero-return stub.
        let needed = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.needed) }
        let relocations = metadata.values.reduce(into: Set<UInt32>()) { $0.formUnion($1.relocationTypes) }
        let dynamicTags = metadata.values.reduce(into: Set<UInt64>()) { $0.formUnion($1.unsupportedDynamicTags) }
        // Match vm_resolve_symbol's existing __ndk1 -> __1 lookup, not a new shim.
        let unresolved = imports.filter { name in
            if exports.contains(name) { return false }
            if handledImports.contains(name) && functionImports.contains(name) &&
                !dataImports.contains(name) && !isSideStoreDataName(name) { return false }
            var converted = name
            if let range = converted.range(of: "6__ndk1") { converted.replaceSubrange(range, with: "3__1") }
            else if let range = converted.range(of: "__ndk1") { converted.replaceSubrange(range, with: "__1") }
            return !exports.contains(converted)
        }
        let fallbackData = unresolved.filter { dataImports.contains($0) || isSideStoreDataName($0) }
        let fallback = unresolved.filter { !fallbackData.contains($0) }
        let blockedData = unresolved.filter { !fallback.contains($0) && !fallbackData.contains($0) }
        let mismatches = metadata.compactMap { name, value -> String? in
            // SONAME is optional in ELF; reject an explicit mismatch, not its absence.
            guard let soname = value.soname, soname != name else { return nil }
            return name
        }
        return Self(profile: profile,
                    missingFiles: Set(profile.filenames).subtracting(provided).sorted(),
                    missingDependencies: needed.subtracting(provided).subtracting(systemLibraries).sorted(),
                    missingEntryPoints: requiredEntryPoints.subtracting(exports).sorted(),
                    unhandledImports: unresolved.sorted(), fallbackFunctionImports: fallback.sorted(), fallbackDataImports: fallbackData.sorted(), unsupportedSymbolImports: unresolved.filter { unsupportedImports.contains($0) }.sorted(), blockedDataImports: blockedData.sorted(),
                    unsupportedRelocations: relocations.subtracting([0, 257, 1025, 1026, 1027]).sorted(),
                    unsupportedDynamicTags: dynamicTags.sorted(), hasThreadLocalSegments: metadata.values.contains { $0.hasThreadLocalSegment }, mismatchedSONAMEs: mismatches.sorted())
    }

    static let maximumFileSize = 64 * 1024 * 1024
    static func readLibrary(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ADIELFMetadata.ParseError.malformed("not a local file URL") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 64, size <= maximumFileSize else {
            throw ADIELFMetadata.ParseError.malformed("not a bounded regular ELF file")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximumFileSize + 1), data.count == size else {
            throw ADIELFMetadata.ParseError.malformed("file changed or incomplete bounded read")
        }
        return data
    }

    static func read(directory: URL, profile: ADILibraryProfile) throws -> Self {
        var metadata: [String: ADIELFMetadata] = [:]
        for name in profile.filenames {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                metadata[name] = try ADIELFMetadata.parse(readLibrary(url))
            }
        }
        return inspect(profile: profile, metadata: metadata)
    }
}
