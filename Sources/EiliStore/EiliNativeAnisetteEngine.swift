import Foundation
import CryptoKit
import ZIPFoundation
import SideSign

/// Apparition 原生 anisette 引擎的 Swift 接線（ODATest #20 實證成功的形狀）：
/// RustLogin crate 本就含 elf／shim／adi 三件（與 ODATest 同一份代碼），這裡
/// 只負責 Swift 側的三件事——下載 4.9.6 原配運行庫、呼叫
/// `apparition_adi_init` 啟動引擎（原生執行，需 TrollStore 開 JIT）、登入
/// 成功後取一組 OTP 組成 SideSign.AnisetteData 快照供保存 session。
/// 佈建與登入本身全在 Rust 內（LocalAdiProvider＋isideload）。
final class EiliNativeAnisetteEngine {
    static let shared = EiliNativeAnisetteEngine()
    private init() {}

    enum NativeEngineError: LocalizedError {
        case libraries(String)
        case engineInit(String)

        var errorDescription: String? {
            switch self {
            case .libraries(let message): return "原生引擎運行庫就位失敗：\(message)"
            case .engineInit(let message): return "原生引擎啟動失敗：\(message)"
            }
        }
    }

    static let libsSourceURL = URL(string: "https://raw.githubusercontent.com/yongshuai1013/EiliStore/main/oda/applemusic-4.9.6-oda.json")!

    private var engineStarted = false

    // MARK: - 路徑（自成一區，與 ODA／Unicorn 的 adi.pb 完全隔離）

    var baseDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeAnisette", isDirectory: true)
    }
    var libsDir: URL { baseDir.appendingPathComponent("libs", isDirectory: true) }
    var provDir: URL { baseDir.appendingPathComponent("provisioning", isDirectory: true) }
    var servicesPath: URL { libsDir.appendingPathComponent("libstoreservicescore.so") }
    var corePath: URL { libsDir.appendingPathComponent("libCoreADI.so") }
    var diagURL: URL { baseDir.appendingPathComponent("rust-diagnostics.txt") }

    /// 原生引擎自己的裝置身份（持久化複用，adi.pb 與它成對）。
    var identifier: UUID {
        let key = "eilistore.nativeAnisette.identifier"
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) {
            return u
        }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }

    private var identifierBytes: [UInt8] {
        let u = identifier
        return [u.uuid.0, u.uuid.1, u.uuid.2, u.uuid.3, u.uuid.4, u.uuid.5, u.uuid.6, u.uuid.7,
                u.uuid.8, u.uuid.9, u.uuid.10, u.uuid.11, u.uuid.12, u.uuid.13, u.uuid.14, u.uuid.15]
    }

    /// X-Apple-I-MD-LU：identifier 16 位元組的 SHA-256（hex 小寫）。
    var mdLU: String {
        SHA256.hash(data: Data(identifierBytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 準備（下載庫＋啟動引擎，冪等）

    /// 登入前呼叫：庫就位、引擎啟動。`log` 用來把進度寫進登入日誌。
    func prepare(log: @escaping (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        apparition_set_diagnostic_log(diagURL.path)
        try await ensureLibraries(log: log)
        try ensureEngine(log: log)
    }

    private func ensureLibraries(log: (String) -> Void) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: servicesPath.path), fm.fileExists(atPath: corePath.path) {
            return
        }
        log("原生引擎：下載運行庫（Apple Music 4.9.6 原配）…")
        let data: Data
        do {
            let (downloaded, _) = try await URLSession.shared.data(from: Self.libsSourceURL)
            data = downloaded
        } catch {
            throw NativeEngineError.libraries("下載失敗：\(error.localizedDescription)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["l"] as? String,
              let payload = Data(base64Encoded: b64) else {
            throw NativeEngineError.libraries("oda.json 格式不符")
        }
        if let expected = obj["s"] as? String {
            let hex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            log(hex == expected.lowercased() ? "原生引擎：庫包 SHA-256 一致" : "原生引擎：⚠️ 庫包 SHA-256 與目錄不符，繼續嘗試")
        }
        do {
            try fm.createDirectory(at: libsDir, withIntermediateDirectories: true)
            let zipURL = baseDir.appendingPathComponent("oda-libs.zip")
            try payload.write(to: zipURL)
            let tmp = baseDir.appendingPathComponent("unzipped-\(UUID().uuidString)", isDirectory: true)
            try fm.unzipItem(at: zipURL, to: tmp)
            defer { try? fm.removeItem(at: tmp) }
            var foundServices: URL?
            var foundCore: URL?
            if let en = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
                for case let url as URL in en {
                    if url.lastPathComponent == "libstoreservicescore.so" { foundServices = url }
                    if url.lastPathComponent == "libCoreADI.so" { foundCore = url }
                }
            }
            guard let s = foundServices, let c = foundCore else {
                throw NativeEngineError.libraries("庫包裡找不到兩支 .so")
            }
            try? fm.removeItem(at: servicesPath)
            try? fm.removeItem(at: corePath)
            try fm.copyItem(at: s, to: servicesPath)
            try fm.copyItem(at: c, to: corePath)
        } catch let error as NativeEngineError {
            throw error
        } catch {
            throw NativeEngineError.libraries("解壓失敗：\(error.localizedDescription)")
        }
        log("原生引擎：運行庫就位")
    }

    private func ensureEngine(log: (String) -> Void) throws {
        if engineStarted { return }
        try FileManager.default.createDirectory(at: provDir, withIntermediateDirectories: true)
        log("原生引擎：啟動（原生載入 .so，需已開 JIT）…")
        // CoreADI 的 set_identifier 只收 16 字元識別碼（UUID 連字號形式前 16 字元）。
        let adiIdentifier = String(identifier.uuidString.prefix(16))
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc = apparition_adi_init(servicesPath.path, corePath.path, provDir.path, adiIdentifier, &errBuf, errBuf.count)
        guard rc == 0 else {
            throw NativeEngineError.engineInit("rc=\(rc)：\(String(cString: errBuf))（未開 JIT 時原生載入會失敗）")
        }
        engineStarted = true
        log("原生引擎：已啟動，login_code = \(apparition_adi_login_code())（0 = 已佈建）")
    }

    // MARK: - 登入成功後的 anisette 快照

    /// 引擎此時必已佈建（登入成功的前提）：取一組 OTP 組成與 SideSign 登入
    /// 同形的 AnisetteData，僅供 AuthSession 保存用（實際登入用的是 Rust 內
    /// 自取的 OTP）。取不到時回 nil，呼叫方以空快照錯誤處理。
    func snapshotAnisette() -> SideSign.AnisetteData? {
        var mid = [UInt8](repeating: 0, count: 4096)
        var otp = [UInt8](repeating: 0, count: 4096)
        var midOut = 0
        var otpOut = 0
        let rc = mid.withUnsafeMutableBufferPointer { m in
            otp.withUnsafeMutableBufferPointer { o in
                apparition_adi_request_otp(m.baseAddress, 4096, &midOut, o.baseAddress, 4096, &otpOut)
            }
        }
        guard rc == 0, midOut > 0, otpOut > 0 else { return nil }
        return SideSign.AnisetteData(
            machineID: Data(mid.prefix(midOut)).base64EncodedString(),
            oneTimePassword: Data(otp.prefix(otpOut)).base64EncodedString(),
            localUserID: mdLU,
            routingInfo: "17106176",
            deviceID: identifier.uuidString,
            serialNumber: "0",
            clientInfo: "<Pixel 8><Android; 14; UQ1A.240205.004><com.apple.AuthKit/1 (com.apple.android.music/4.9.6)>",
            userAgent: "akd/1.0 CFNetwork/808.1.4",
            clientTime: ISO8601DateFormatter().string(from: Date()),
            locale: "en_US",
            timeZone: TimeZone.current.identifier
        )
    }
}
