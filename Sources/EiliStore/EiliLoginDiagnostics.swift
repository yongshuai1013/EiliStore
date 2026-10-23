import Foundation

/// Fixed vocabulary and numeric status only: never pass credentials, headers, URLs,
/// free-form errors or provider payloads here.
/// This is a last-known-stage journal, NOT a crash handler or proof of an OS termination reason.
final class EiliLoginDiagnostics: @unchecked Sendable {
    static let shared = EiliLoginDiagnostics()

    enum Stage: String, Codable, Sendable {
        case providerCreating, providerReady, loadingStateSet, loginCallbacksReady
        case loginTaskCreating, loginTaskCreated, loginTaskEntered, authServiceCalling, authServiceEntered
        case loginTapped, loginStarted, configurationLoading, configurationReady
        case anisetteWaiting, remoteRequestStarted, remoteRequestReturned
        case localPreflightStarted, localPreflightPassed, localAcquisitionStarted
        case localClientCreating, localClientReady, localRequestStarted, localRequestReturned
        case nativeHeadersStarted, nativeHeadersReturned
        case nativeProvisionStartStarted, nativeProvisionStartReturned
        case nativeProvisionEndStarted, nativeProvisionEndReturned
        case nativeBoundaryReturned, nativeResponseParsed, nativeResponseFailed
        case anisetteReady, authenticationStarted, verificationWaiting
        case authenticationReturned, sessionSaving
    }
    enum Outcome: String, Codable { case unfinished, succeeded, failed, cancelled }
    struct NativeDetail: Codable, Sendable {
        enum Operation: String, Codable, Sendable { case headers, provisionStart, provisionEnd }
        enum Result: String, Codable, Sendable {
            case boundaryReturned, parsed, nilResponse, invalidJSON, invalidResponse, providerError
        }
        enum Phase: String, Codable, Sendable {
            case arguments, vmAllocation, vmInitialization, libraryLoad, libraryRelocation
            case libraryConstructors, loadLibrarySymbol, loadLibrary, provisioningDirectory
            case setProvisioningPathSymbol, setProvisioningPath, setAndroidIDSymbol, setAndroidID
            case provisionStartSymbol, provisionStart, provisionStartOutput, exception
        }
        let operation: Operation
        let result: Result
        let phase: Phase?
        let code: Int32
        let nativeCode: Int32?
    }
    struct Entry: Codable {
        let stage: Stage
        let date: Date
        // Optional keeps existing v2 journals readable without migrating or deleting them.
        var native: NativeDetail? = nil
    }
    struct Attempt: Codable {
        let id: UUID
        let mode: String
        let build: String
        let os: String
        var entries: [Entry]
        var outcome: Outcome
    }
    private struct Journal: Codable { var current: Attempt?; var previous: Attempt? }
    private let lock = NSLock()
    private let file: URL
    private var journal = Journal()
    private var writeFailed = false

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EiliStore/Diagnostics/login-stages.json")
        if let size = try? self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 65536, let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode(Journal.self, from: data) {
            journal = saved
        }
    }

    @discardableResult
    func begin(onDevice: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        journal.previous = journal.current
        journal.current = Attempt(id: id, mode: onDevice ? "onDevice" : "remote",
            build: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))",
            os: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            entries: [Entry(stage: .loginTapped, date: Date())], outcome: .unfinished)
        persist()
        return id
    }

    static func record(_ stage: Stage, for id: UUID?) {
        guard let id else { return }
        shared.record(stage, for: id)
    }

    /// The serialized Anisette service rebinds this for each request, including nil.
    /// A cached native provider must not retain the first login's ID or depend on
    /// task-local propagation through Swift async / synchronous native boundaries.
    final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UUID?
        private let store: EiliLoginDiagnostics

        init(store: EiliLoginDiagnostics = .shared) { self.store = store }

        func bind(_ id: UUID?) {
            lock.lock(); defer { lock.unlock() }
            self.id = id
        }

        func record(_ stage: Stage) {
            lock.lock(); defer { lock.unlock() }
            guard let id else { return }
            store.record(stage, for: id)
        }

        func record(native: NativeDetail) {
            lock.lock(); defer { lock.unlock() }
            guard let id else { return }
            store.record(native: native, for: id)
        }
    }

    func record(_ stage: Stage, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard journal.current?.id == id, journal.current?.outcome == .unfinished else { return }
        journal.current?.entries.append(Entry(stage: stage, date: Date()))
        if let count = journal.current?.entries.count, count > 48 {
            journal.current?.entries.removeFirst(count - 48)
        }
        persist()
    }

    func record(native: NativeDetail, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard journal.current?.id == id, journal.current?.outcome == .unfinished else { return }
        let stage: Stage
        switch native.result {
        case .boundaryReturned: stage = .nativeBoundaryReturned
        case .parsed: stage = .nativeResponseParsed
        default: stage = .nativeResponseFailed
        }
        journal.current?.entries.append(Entry(stage: stage, date: Date(), native: native))
        if let count = journal.current?.entries.count, count > 48 {
            journal.current?.entries.removeFirst(count - 48)
        }
        persist()
    }

    func finish(_ outcome: Outcome, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard journal.current?.id == id, journal.current?.outcome == .unfinished else { return }
        journal.current?.outcome = outcome
        persist()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        journal = Journal()
        persist()
    }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        var lines = ["EiliStore 登入階段診斷 v3", "僅記錄固定階段、數字狀態碼、時間、模式及版本；不含帳號、密碼、驗證碼、Session 或 Anisette 內容。", "未完成不等於已確認閃退；也可能是強制關閉或系統終止。", "bridge 為 C 邊界回傳碼；native 為 VM 呼叫回傳碼，不一定是 Apple 錯誤碼。"]
        if writeFailed { lines.append("注意：診斷寫入失敗，重開後的紀錄可能不完整。") }
        let formatter = ISO8601DateFormatter()
        for (label, attempt) in [("最近一次", journal.current), ("前一次", journal.previous)] {
            guard let attempt else { continue }
            lines += ["", "\(label)：\(attempt.outcome.rawValue)", "模式：\(attempt.mode)；App：\(attempt.build)；系統：\(attempt.os)"]
            lines += attempt.entries.map { entry in
                var line = "\(formatter.string(from: entry.date)) \(entry.stage.rawValue)"
                if let native = entry.native {
                    line += " op=\(native.operation.rawValue) result=\(native.result.rawValue) bridge=\(native.code)"
                    if let phase = native.phase { line += " phase=\(phase.rawValue)" }
                    if let code = native.nativeCode {
                        line += " native=\(code) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
                    }
                }
                return line
            }
        }
        if journal.current == nil { lines.append("尚無登入階段紀錄。") }
        return lines.joined(separator: "\n")
    }

    /// Persist before entering risky work. No signal/exception handlers, no network, bounded storage.
    private func persist() {
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(journal)
            try data.write(to: file, options: .atomic)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
            writeFailed = false
        } catch {
            // Diagnostics must never turn an otherwise recoverable login into a failure.
            writeFailed = true
        }
    }
}
