import Foundation
import ZIPFoundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SideStore-compatible direct ODA metadata. The metadata's hash checks integrity,
/// not authenticity: it is deliberately NOT described as an independent pin.
struct ADIRuntimeLibraryDownloader: @unchecked Sendable {
    static let defaultMetadataURL = URL(string: "https://zzz.haus/oda.json")!
    struct Limits: Sendable {
        var metadataBytes: Int = 16 * 1024 * 1024
        var archiveBytes: Int = 64 * 1024 * 1024
        var fileBytes: UInt64 = 64 * 1024 * 1024
        var expandedBytes: UInt64 = 128 * 1024 * 1024
    }
    let metadataURL: URL
    private let configuration: URLSessionConfiguration
    private let limits: Limits

    init(metadataURL: URL = Self.defaultMetadataURL,
         configuration: URLSessionConfiguration = .ephemeral, limits: Limits = .init()) {
        self.metadataURL = metadataURL
        // Own an immutable snapshot; a caller cannot mutate policy during a request.
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        copy.httpAdditionalHeaders = nil
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.timeoutIntervalForRequest = 30
        copy.timeoutIntervalForResource = 120
        self.configuration = copy
        self.limits = limits
    }

    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
            && url.user == nil && url.password == nil
    }

    func stageLibraries(in directory: URL) async throws -> [URL] {
        do {
            try Task.checkCancellation()
            guard limits.metadataBytes > 0, limits.archiveBytes > 0,
                  limits.fileBytes > 64, limits.expandedBytes > 64 else { throw DownloadError.large }
            let meta = try await request(metadataURL, limit: limits.metadataBytes)
            guard let obj = try JSONSerialization.jsonObject(with: meta) as? [String: Any] else { throw DownloadError.metadata }
            let digest = ["sha256", "sha", "s"].compactMap { obj[$0] as? String }.first
            guard let digest, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw DownloadError.metadata
            }
            guard let raw = ["l", "libraries", "payload", "data", "url"].compactMap({ obj[$0] as? String }).first else {
                throw DownloadError.metadata
            }
            let payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let archiveData: Data
            if let url = URL(string: payload), url.scheme != nil {
                archiveData = try await request(url, limit: limits.archiveBytes)
            } else {
                guard let data = Data(base64Encoded: payload) else { throw DownloadError.metadata }
                guard data.count <= limits.archiveBytes else { throw DownloadError.large }
                archiveData = data
            }
            try Task.checkCancellation()
            let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(digest) == .orderedSame else { throw DownloadError.hash }
            return try extract(archiveData, into: directory)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.invalid
        }
    }

    private func request(_ url: URL, limit: Int) async throws -> Data {
        guard Self.isSecure(url) else { throw DownloadError.insecure }
        let transfer = BoundedTransfer(configuration: configuration, limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(url: url, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private func extract(_ data: Data, into directory: URL) throws -> [URL] {
        let fm = FileManager.default
        // Caller owns a private, empty staging directory. Never append to existing
        // output (including symlinks); installation is a separate atomic transaction.
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isFileURL, values.isDirectory == true, values.isSymbolicLink != true,
              try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { throw DownloadError.archive }
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw DownloadError.archive }
        var entries: [Entry] = []
        for entry in archive {
            guard entries.count < 5 else { throw DownloadError.archive }
            entries.append(entry)
        }
        guard entries.count == 2 || entries.count == 5 else { throw DownloadError.archive }
        let permitted: Set<String> = entries.count == 2
            ? ["libCoreADI.so", "libstoreservicescore.so"]
            : ["libCoreADI.so", "libCoreFP.so", "libCoreLSKD.so", "libFPDIFor3P.so", "libstoreapi.so"]
        var seen = Set<String>(), total: UInt64 = 0
        for entry in entries {
            // Permitted names are ASCII (and therefore UTF-8). Do not rely on
            // platform-specific DOS codepage support for ZIP's default encoding.
            let name = entry.path(using: .utf8)
            guard permitted.contains(name), seen.insert(name).inserted,
                  entry.type == .file, entry.uncompressedSize > 64 else { throw DownloadError.archive }
            guard entry.uncompressedSize <= limits.fileBytes,
                  entry.uncompressedSize <= limits.expandedBytes - min(total, limits.expandedBytes) else { throw DownloadError.large }
            total += entry.uncompressedSize
        }
        guard seen == permitted else { throw DownloadError.archive }
        for entry in entries {
            try Task.checkCancellation()
            let output = directory.appendingPathComponent(entry.path(using: .utf8))
            guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DownloadError.archive
            }
            let handle = try FileHandle(forWritingTo: output)
            do {
                defer { try? handle.close() }
                var written: UInt64 = 0
                let crc = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: false) { chunk in
                    try Task.checkCancellation()
                    guard UInt64(chunk.count) <= entry.uncompressedSize - min(written, entry.uncompressedSize),
                          UInt64(chunk.count) <= limits.fileBytes - min(written, limits.fileBytes) else { throw DownloadError.large }
                    written += UInt64(chunk.count)
                    try handle.write(contentsOf: chunk)
                }
                // ZIPFoundation's consumer API RETURNS the checksum; it does not
                // compare it against the archive's CRC for us.
                guard crc == entry.checksum, written == entry.uncompressedSize else { throw DownloadError.archive }
            } catch is CancellationError { throw CancellationError() }
            catch let error as DownloadError { throw error }
            catch { throw DownloadError.archive }
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let header = [UInt8](try reader.read(upToCount: 64) ?? Data())
            guard header.count == 64, Array(header[0..<4]) == [0x7f, 0x45, 0x4c, 0x46],
                  header[4] == 2, header[5] == 1, header[6] == 1,
                  header[16] == 3, header[17] == 0, header[18] == 183, header[19] == 0 else {
                throw DownloadError.elf
            }
        }
        return permitted.sorted().map { directory.appendingPathComponent($0) }
    }

    enum DownloadError: LocalizedError, Equatable {
        case insecure, metadata, network, large, hash, archive, elf, invalid, cancelled
        var errorDescription: String? {
            switch self {
            case .insecure: return "下載來源必須使用 HTTPS，且重新導向不得降級。"
            case .metadata: return "ADI 函式庫中繼資料格式無效或缺少 SHA-256。"
            case .network: return "無法取得 ADI 函式庫，請檢查連線後重試。"
            case .large: return "ADI 函式庫超過安全大小限制。"
            case .hash: return "ADI 函式庫 SHA-256 驗證失敗；原有函式庫未變更。"
            case .archive: return "ADI 函式庫 ZIP 結構不安全、損毀或不受支援。"
            case .elf: return "ADI 函式庫不是有效的 ELF64 AArch64 檔案。"
            case .cancelled: return "ADI 函式庫下載已取消。"
            case .invalid: return "ADI 函式庫下載或驗證失敗。"
            }
        }
    }

    /// Delegate callbacks and task cancellation may run concurrently. All mutable
    /// state is locked; completion resumes the continuation exactly once.
    private final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let configuration: URLSessionConfiguration
        private let limit: Int
        private var bytes = Data()
        private var continuation: CheckedContinuation<Data, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var cancelled = false
        private var redirects = 0
        private var acceptedResponse = false
        init(configuration: URLSessionConfiguration, limit: Int) {
            self.configuration = configuration
            self.limit = limit
        }
        func start(url: URL, continuation: CheckedContinuation<Data, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            finish(.failure(CancellationError()))
        }
        private func finish(_ result: Result<Data, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            self.task = nil
            bytes = Data()
            lock.unlock()
            session?.invalidateAndCancel()
            continuation?.resume(with: result)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            lock.lock(); redirects += 1; let count = redirects; lock.unlock()
            guard let url = request.url, ADIRuntimeLibraryDownloader.isSecure(url) else {
                completionHandler(nil); finish(.failure(DownloadError.insecure)); return
            }
            guard count <= 5 else { completionHandler(nil); finish(.failure(DownloadError.network)); return }
            // Make a fresh GET: never forward cookies or authorization between hosts.
            var clean = URLRequest(url: url)
            clean.httpShouldHandleCookies = false
            completionHandler(clean)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let url = response.url, ADIRuntimeLibraryDownloader.isSecure(url) else {
                completionHandler(.cancel); finish(.failure(DownloadError.insecure)); return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completionHandler(.cancel); finish(.failure(DownloadError.network)); return
            }
            guard response.expectedContentLength <= Int64(limit) else {
                completionHandler(.cancel); finish(.failure(DownloadError.large)); return
            }
            lock.lock(); acceptedResponse = true; lock.unlock()
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard continuation != nil else { lock.unlock(); return }
            guard data.count <= limit - bytes.count else {
                lock.unlock(); finish(.failure(DownloadError.large)); return
            }
            bytes.append(data)
            lock.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let result: Result<Data, Error>
            if cancelled { result = .failure(CancellationError()) }
            else if error != nil || !acceptedResponse { result = .failure(DownloadError.network) }
            else { result = .success(bytes) }
            lock.unlock()
            finish(result)
        }
    }
}
