import Foundation
import XCTest
@testable import Downloader
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockURLProtocol: URLProtocol {
    struct Reply {
        let status: Int; let data: Data; let delay: TimeInterval
        var omitLength = false
        var chunkSize = 0
    }
    static let lock = NSLock()
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requestCount = 0
    private let cancellationLock = NSLock()
    private var stopped = false
    private var isStopped: Bool { cancellationLock.lock(); defer { cancellationLock.unlock() }; return stopped }
    static func set(_ reply: Reply, for path: String) { lock.lock(); replies[path] = reply; lock.unlock() }
    static func clear() { lock.lock(); replies.removeAll(); requestCount = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requestCount += 1; let reply = Self.replies[request.url!.path]; Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        guard !isStopped else { return }
        let headers = reply.omitLength ? [:] : ["Content-Length": "\(reply.data.count)"]
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = reply.chunkSize > 0 ? reply.chunkSize : max(reply.data.count, 1)
        for offset in stride(from: 0, to: reply.data.count, by: size) {
            guard !isStopped else { return }
            client?.urlProtocol(self, didLoad: reply.data.subdata(in: offset..<min(offset + size, reply.data.count)))
        }
        if !isStopped { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { cancellationLock.lock(); stopped = true; cancellationLock.unlock() }
}

final class ADIRuntimeLibraryDownloaderTests: XCTestCase {
    private final class Warnings: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func append(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    }
    private let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ADI_TEST_FIXTURES"]!, isDirectory: true)
    private let metadataURL = URL(string: "https://mock.test/metadata")!
    private var stagedDirectories: [URL] = []
    override func tearDown() {
        for directory in stagedDirectories { try? FileManager.default.removeItem(at: directory) }
        stagedDirectories.removeAll()
        super.tearDown()
    }
    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func makeDownloader(_ archive: String? = "valid.zip", status: Int = 200, delay: TimeInterval = 0, limits: ADIRuntimeLibraryDownloader.Limits = .init(), warnings: Warnings? = nil) throws -> ADIRuntimeLibraryDownloader {
        MockURLProtocol.clear()
        let archiveData = try archive.map(data) ?? data("valid.zip")
        let digestName = archive ?? "valid.zip"
        let digest = try String(contentsOf: fixtures.appendingPathComponent(digestName + ".sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = archive.map { _ in "\"l\":\"\(archiveData.base64EncodedString())\"," } ?? ""
        let json = Data("{\"sha256\":\"\(digest)\",\(payload)\"url\":\"https://mock.test/archive\"}".utf8)
        MockURLProtocol.set(.init(status: 200, data: json, delay: 0), for: "/metadata")
        MockURLProtocol.set(.init(status: status, data: archiveData, delay: delay), for: "/archive")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return ADIRuntimeLibraryDownloader(metadataURL: metadataURL, configuration: config, limits: limits,
            warningHandler: { warnings?.append($0) })
    }
    private func stageDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        stagedDirectories.append(url)
        return url
    }
    private func assertFailure(_ expected: ADIRuntimeLibraryDownloader.DownloadError, downloader: ADIRuntimeLibraryDownloader, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await downloader.stageLibraries(in: try stageDir()); XCTFail("Expected \\(expected)", file: file, line: line) }
        catch let error as ADIRuntimeLibraryDownloader.DownloadError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error: \\(error)", file: file, line: line) }
    }
    func testDownloadsAndStagesInlineAndHTTPSArchive() async throws {
        let inline = try makeDownloader("valid.zip")
        let dir = try stageDir(); let paths = try await inline.stageLibraries(in: dir)
        XCTAssertEqual(paths.map(\.lastPathComponent), ["libCoreADI.so", "libstoreservicescore.so"])
        XCTAssertEqual(try Data(contentsOf: paths[0]), try data("valid.elf"))
        let remote = try makeDownloader(nil)
        let rdir = try stageDir(); let remotePaths = try await remote.stageLibraries(in: rdir)
        XCTAssertEqual(remotePaths.map(\.lastPathComponent), ["libCoreADI.so", "libstoreservicescore.so"])
        XCTAssertEqual(try Data(contentsOf: remotePaths[0]), try data("valid.elf"))
    }
    private func setMismatchedMetadata(_ archive: String?, key: String = "s") throws {
        let payload = try archive.map { "\"l\":\"\(try data($0).base64EncodedString())\"" }
            ?? "\"url\":\"https://mock.test/archive\""
        let json = "{\"\(key)\":\"\(String(repeating: "0", count: 64))\",\(payload)}"
        MockURLProtocol.set(.init(status: 200, data: Data(json.utf8), delay: 0), for: "/metadata")
    }
    func testWrongDigestWarnsAndStagesInlineAndHTTPSArchive() async throws {
        for key in ["s", "sha", "sha256"] {
            for archive: String? in ["valid.zip", nil] {
                let warnings = Warnings()
                let d = try makeDownloader(archive, warnings: warnings)
                try setMismatchedMetadata(archive, key: key)
                let paths = try await d.stageLibraries(in: try stageDir())
                XCTAssertEqual(paths.map(\.lastPathComponent), ["libCoreADI.so", "libstoreservicescore.so"])
                for path in paths { XCTAssertEqual(try Data(contentsOf: path), try data("valid.elf")) }
                XCTAssertEqual(warnings.values.count, 1)
                XCTAssertTrue(warnings.values.first?.contains("SHA-256") == true)
            }
        }
    }
    func testMatchingDigestDoesNotWarnIncludingUppercase() async throws {
        let warnings = Warnings()
        let d = try makeDownloader(warnings: warnings)
        let digest = try String(contentsOf: fixtures.appendingPathComponent("valid.zip.sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let json = "{\"s\":\"\(digest)\",\"l\":\"\(try data("valid.zip").base64EncodedString())\"}"
        MockURLProtocol.set(.init(status: 200, data: Data(json.utf8), delay: 0), for: "/metadata")
        _ = try await d.stageLibraries(in: try stageDir())
        XCTAssertTrue(warnings.values.isEmpty)
    }
    func testWrongDigestDoesNotBypassArchiveELFOrSizeChecks() async throws {
        for (archive, expected) in [("traversal.zip", ADIRuntimeLibraryDownloader.DownloadError.archive),
            ("duplicate.zip", .archive), ("symlink.zip", .archive), ("extra.zip", .archive),
            ("crc.zip", .archive), ("invalid-elf.zip", .elf), ("bomb.zip", .large)] {
            let warnings = Warnings()
            let d = try makeDownloader(archive, limits: .init(expandedBytes: archive == "bomb.zip" ? 511 : 512), warnings: warnings)
            try setMismatchedMetadata(archive)
            await assertFailure(expected, downloader: d)
            XCTAssertEqual(warnings.values.count, 1)
        }
    }
    func testWrongDigestNeverOverwritesNonemptyStagingDirectory() async throws {
        let d = try makeDownloader()
        try setMismatchedMetadata("valid.zip")
        let directory = try stageDir()
        let existing = directory.appendingPathComponent("libCoreADI.so")
        let original = Data("existing library sentinel".utf8)
        try original.write(to: existing)
        do { _ = try await d.stageLibraries(in: directory); XCTFail("nonempty staging accepted") }
        catch let error as ADIRuntimeLibraryDownloader.DownloadError { XCTAssertEqual(error, .archive) }
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["libCoreADI.so"])
    }
    func testRequiresHash() async throws {
        let d = try makeDownloader("valid.zip"); MockURLProtocol.set(.init(status: 200, data: Data("{\"l\":\"\(try data("valid.zip").base64EncodedString())\"}".utf8), delay: 0), for: "/metadata")
        await assertFailure(.metadata, downloader: d)
    }
    func testHTTPRejectedBeforeNetwork() async throws {
        let d = ADIRuntimeLibraryDownloader(metadataURL: URL(string: "http://mock.test/metadata")!)
        await assertFailure(.insecure, downloader: d)
    }
    func testMetadataResponseSizeLimit() async throws {
        let d = try makeDownloader("valid.zip", limits: .init(metadataBytes: 32, archiveBytes: 1_000_000, fileBytes: 1_000_000, expandedBytes: 2_000_000))
        await assertFailure(.large, downloader: d)
    }
    func testHTTPStatusRejected() async throws { await assertFailure(.network, downloader: try makeDownloader(nil, status: 503)) }
    func testUnknownLengthChunkedMetadataIsBounded() async throws {
        let d = try makeDownloader(limits: .init(metadataBytes: 32))
        MockURLProtocol.set(.init(status: 200, data: Data(repeating: 65, count: 100), delay: 0, omitLength: true, chunkSize: 16), for: "/metadata")
        await assertFailure(.large, downloader: d)
    }
    func testArchiveResponseSizeLimit() async throws {
        let d = try makeDownloader(nil, limits: .init(archiveBytes: 100))
        await assertFailure(.large, downloader: d)
    }
    func testUnknownLengthChunkedArchiveIsBounded() async throws {
        let d = try makeDownloader(nil, limits: .init(archiveBytes: 100))
        MockURLProtocol.set(.init(status: 200, data: try data("valid.zip"), delay: 0, omitLength: true, chunkSize: 16), for: "/archive")
        await assertFailure(.large, downloader: d)
    }
    func testPerFileExpandedLimit() async throws {
        await assertFailure(.large, downloader: try makeDownloader("valid.zip", limits: .init(fileBytes: 128)))
    }
    func testInsecurePayloadURLRejected() async throws {
        let d = try makeDownloader(nil)
        let json = "{\"s\":\"\(String(repeating: "a", count: 64))\",\"url\":\"http://mock.test/archive\"}"
        MockURLProtocol.set(.init(status: 200, data: Data(json.utf8), delay: 0), for: "/metadata")
        await assertFailure(.insecure, downloader: d)
    }
    func testSecureURLPolicyRejectsCredentialsAndDowngrade() {
        XCTAssertTrue(ADIRuntimeLibraryDownloader.isSecure(URL(string: "https://mock.test/library.zip")!))
        for raw in ["http://mock.test/archive", "file:///tmp/archive", "https://user:password@mock.test/archive"] {
            XCTAssertFalse(ADIRuntimeLibraryDownloader.isSecure(URL(string: raw)!))
        }
    }
    func testRejectsUnsafeArchives() async throws {
        for name in ["traversal.zip", "duplicate.zip", "symlink.zip", "extra.zip", "crc.zip"] {
            await assertFailure(.archive, downloader: try makeDownloader(name))
        }
    }
    func testRejectsInvalidELF() async throws { await assertFailure(.elf, downloader: try makeDownloader("invalid-elf.zip")) }
    func testRejectsExpandedSizeBomb() async throws {
        let d = try makeDownloader("bomb.zip", limits: .init(metadataBytes: 1_000_000, archiveBytes: 1_000_000, fileBytes: 1_000_000, expandedBytes: 400))
        await assertFailure(.large, downloader: d)
    }
    func testPrecancelledTaskDoesNotStartMockRequest() async throws {
        let d = try makeDownloader(nil)
        let dir = try stageDir()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await d.stageLibraries(in: dir)
        }
        do { _ = try await task.value; XCTFail("precancelled request succeeded") }
        catch is CancellationError { }
        catch let error as ADIRuntimeLibraryDownloader.DownloadError { XCTAssertEqual(error, .cancelled) }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }
    func testCancellationStopsRequest() async throws {
        let d = try makeDownloader(nil, delay: 2)
        let dir = try stageDir()
        let task = Task { try await d.stageLibraries(in: dir) }
        try await Task.sleep(nanoseconds: 40_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request succeeded") }
        catch is CancellationError { }
        catch let error as ADIRuntimeLibraryDownloader.DownloadError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("unexpected cancellation error: \\(error)") }
    }
}
