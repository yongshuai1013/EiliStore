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
    let unsupportedRelocations: [UInt32]
    let unsupportedDynamicTags: [UInt64]
    let mismatchedSONAMEs: [String]

    // This is an explicit capability gate, not a claim that static linking proves runtime safety.
    // libstoreapi requires a new Android ABI adapter; do not send it into the legacy zero-stub loader.
    var runtimeAdapterAvailable: Bool { profile == .legacy }
    var hasStaticBlockers: Bool {
        !missingFiles.isEmpty || !missingDependencies.isEmpty || !missingEntryPoints.isEmpty ||
        !unhandledImports.isEmpty || !unsupportedRelocations.isEmpty ||
        !unsupportedDynamicTags.isEmpty || !mismatchedSONAMEs.isEmpty
    }
    var summary: String {
        var parts: [String] = []
        if !runtimeAdapterAvailable { parts.append("已識別新版 libstoreapi 庫組，但目前引擎尚未支援其 Android ABI") }
        if !missingFiles.isEmpty { parts.append("缺少 \(missingFiles.joined(separator: ", "))") }
        if !missingDependencies.isEmpty { parts.append("另有 \(missingDependencies.count) 個未提供的相依庫") }
        if !missingEntryPoints.isEmpty { parts.append("缺少 \(missingEntryPoints.count) 個必要 ADI 入口") }
        if !unhandledImports.isEmpty { parts.append("\(unhandledImports.count) 個外部符號尚無明確實作") }
        if !unsupportedRelocations.isEmpty { parts.append("\(unsupportedRelocations.count) 種重定位尚未支援") }
        if !unsupportedDynamicTags.isEmpty { parts.append("含尚未支援的動態連結格式") }
        if !mismatchedSONAMEs.isEmpty { parts.append("函式庫內部名稱與檔名不符，請勿改名混用") }
        if parts.isEmpty { parts.append("靜態檢查未發現已知阻礙，但不代表實際登入已驗證") }
        return parts.joined(separator: "；") + "。未啟動本機引擎，遠端預設不變。"
    }

    static let systemLibraries: Set<String> = ["libc.so", "libdl.so", "liblog.so", "libm.so", "libz.so", "libstdc++.so", "libandroid.so"]
    static let requiredEntryPoints: Set<String> = ["Sph98paBcz", "nf92ngaK92", "kq56gsgHG6", "qi864985u0", "rsegvyrt87", "uv5t6nhkui"]
    // Only explicit branches in import_callback_router count. Its generic zero-return fallback is NOT support.
    static let handledImports: Set<String> = [
        "__android_log_print", "__cxa_allocate_exception", "__cxa_begin_catch", "__cxa_guard_acquire", "__cxa_guard_release", "__dynamic_cast",
        "__errno", "__errno_location", "__system_property_get", "arc4random", "atof", "calloc", "chmod", "close", "dlopen", "dlsym", "free",
        "fstat", "ftruncate", "getauxval", "gettimeofday", "lstat", "malloc", "memchr", "memcmp", "memcpy", "memset", "mkdir", "open",
        "pthread_mutex_init", "pthread_rwlock_init", "read", "realloc", "strcmp", "strcpy", "strlen", "strncmp", "strncpy", "strtod", "strtol", "strtoll", "strtoull", "umask", "write"
    ]

    static func inspect(profile: ADILibraryProfile, metadata: [String: ADIELFMetadata]) -> Self {
        let provided = Set(metadata.keys)
        let exports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.exportedSymbols) }
        let imports = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.undefinedStrongSymbols) }
        let needed = metadata.values.reduce(into: Set<String>()) { $0.formUnion($1.needed) }
        let relocations = metadata.values.reduce(into: Set<UInt32>()) { $0.formUnion($1.relocationTypes) }
        let dynamicTags = metadata.values.reduce(into: Set<UInt64>()) { $0.formUnion($1.unsupportedDynamicTags) }
        let mismatches = metadata.compactMap { name, value -> String? in
            guard value.soname != name else { return nil }
            return name
        }
        return Self(profile: profile,
                    missingFiles: Set(profile.filenames).subtracting(provided).sorted(),
                    missingDependencies: needed.subtracting(provided).subtracting(systemLibraries).sorted(),
                    missingEntryPoints: requiredEntryPoints.subtracting(exports).sorted(),
                    unhandledImports: imports.subtracting(exports).subtracting(handledImports).sorted(),
                    unsupportedRelocations: relocations.subtracting([0, 257, 1025, 1026, 1027]).sorted(),
                    unsupportedDynamicTags: dynamicTags.sorted(), mismatchedSONAMEs: mismatches.sorted())
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
