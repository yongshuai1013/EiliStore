import Foundation
import NIO
import NIOSSL
import Security

/// AFC 協議客戶端（使用 SwiftNIO + BoringSSL，替代 SecureTransport）
public class AFCClient {
    private var channel: Channel?
    private var eventLoopGroup: EventLoopGroup?
    
    static func afcLog(_ msg: String) {
        let line = "[AFC] " + msg + "\n"
        print(line, terminator: "")
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = docs.appendingPathComponent("afc_debug.log")
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let h = try? FileHandle(forWritingTo: url) {
                        h.seekToEndOfFile()
                        h.write(data)
                        try? h.close()
                    }
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
    private var useSSL = false
    private let host: String
    private var packetNum: UInt64 = 0
    
    private let OP_STATUS: UInt64 = 0x01
    private let OP_DATA: UInt64 = 0x02
    private let OP_MKDIR: UInt64 = 0x09
    private let OP_OPEN: UInt64 = 0x0D
    private let OP_OPENRES: UInt64 = 0x0E
    private let OP_WRITE: UInt64 = 0x10
    private let OP_CLOSE: UInt64 = 0x14
    private let FOPEN_WR: UInt64 = 0x04
    
    // 共享的 EventLoopGroup（避免每次建連接都創建）
    private static let sharedGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    
    public init(host: String) {
        self.host = host
    }
    
    /// 從 SecIdentity 提取證書和私鑰，構建 NIOSSL 的 TLS 配置
    private func makeTLSConfiguration(identity: SecIdentity) throws -> TLSConfiguration {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let secCert = cert else {
            throw AFCError.tlsFailed("無法從身份提取證書")
        }
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let secKey = key else {
            throw AFCError.tlsFailed("無法從身份提取私鑰")
        }
        // 證書 DER
        let certData = SecCertificateCopyData(secCert) as Data
        let nioCert = try NIOSSLCertificate(bytes: Array(certData), format: .der)
        // 私鑰：嘗試 DER 格式
        var cfErr: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(secKey, &cfErr) as Data? else {
            throw AFCError.tlsFailed("無法導出私鑰")
        }
        // SecKeyCopyExternalRepresentation 給的是 PKCS#8 DER
        let nioKey = try NIOSSLPrivateKey(bytes: Array(keyData), format: .der)
        
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = [.certificate(nioCert)]
        config.privateKey = .privateKey(nioKey)
        // 不驗證服務器證書（對應之前的 breakOnServerAuth + continue）
        config.trustRoots = .default
        config.certificateVerification = .none
        return config
    }
    
    public func connect(port: UInt16, useSSL: Bool, identity: SecIdentity? = nil) async throws {
        Self.afcLog("CONNECT \(host):\(port) ssl=\(useSSL)")
        if !useSSL {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        self.useSSL = useSSL
        let group = Self.sharedGroup
        self.eventLoopGroup = group
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        
        if useSSL {
            guard let id = identity else { throw AFCError.tlsFailed("無客戶端身份") }
            let tlsConfig = try makeTLSConfiguration(identity: id)
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: "Device")
            let bootstrapWithTLS = bootstrap.channelInitializer { channel in
                channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.addHandler(AFCResponseHandler())
                }
            }
            let ch = try await bootstrapWithTLS.connect(host: host, port: Int(port)).get()
            self.channel = ch
            // 給 TLS 握手一點時間完成（NIOSSL 握手是異步的）
            try await Task.sleep(nanoseconds: 2_000_000_000)
            Self.afcLog("TLS ready")
        } else {
            let bootstrapPlain = bootstrap.channelInitializer { channel in
                channel.pipeline.addHandler(AFCResponseHandler())
            }
            let ch = try await bootstrapPlain.connect(host: host, port: Int(port)).get()
            self.channel = ch
        }
    }
    
    private func sendBytes(_ data: Data) async throws {
        guard let ch = channel else { throw AFCError.notConnected }
        var buffer = ch.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await ch.writeAndFlush(buffer).get()
    }
    
    private func recvBytes(length: Int) async throws -> Data {
        guard let ch = channel else { throw AFCError.notConnected }
        guard let handler = try? await ch.pipeline.handler(type: AFCResponseHandler.self).get() else {
            throw AFCError.notConnected
        }
        return try await handler.read(length: length)
    }
    
    private func nextNum() -> UInt64 {
        let num = packetNum
        packetNum += 1
        return num
    }
    
    private func transact(op: UInt64, headerPayload: Data, payload: Data, opName: String = "未知") async throws -> (op: UInt64, headerPayload: Data, payload: Data) {
        let num = nextNum()
        // DEBUG: log outgoing packet
        Self.afcLog(">>> \(opName) op=0x\(String(format: "%02X", op)) num=\(num) hpLen=\(headerPayload.count) payloadLen=\(payload.count)")
        Self.afcLog(">>> hp hex: \(headerPayload.map { String(format: "%02x", $0) }.joined())")
        var header = Data()
        header.append("CFA6LPAA".data(using: .ascii)!)
        var entireLen = UInt64(40 + headerPayload.count + payload.count).littleEndian
        header.append(Data(bytes: &entireLen, count: 8))
        var hpLen = UInt64(40 + headerPayload.count).littleEndian
        header.append(Data(bytes: &hpLen, count: 8))
        var numLE = num.littleEndian
        header.append(Data(bytes: &numLE, count: 8))
        var opLE = op.littleEndian
        header.append(Data(bytes: &opLE, count: 8))
        try await sendBytes(header + headerPayload + payload)
        let respHeader: Data
        do {
            respHeader = try await recvBytes(length: 40)
        } catch {
            throw AFCError.operationFailed("\(opName): 讀回應頭失敗: \(error)")
        }
        guard respHeader.prefix(8) == "CFA6LPAA".data(using: .ascii)! else {
            Self.afcLog("<<< \(opName) INVALID MAGIC")
            throw AFCError.invalidResponse
        }
        let respEntireLen = respHeader[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respHpLen = respHeader[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respOp = respHeader[32..<40].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        Self.afcLog("<<< \(opName) respOp=0x\(String(format: "%02X", respOp)) entireLen=\(respEntireLen) hpLen=\(respHpLen)")
        var respHp = Data()
        let hpToRead = Int(respHpLen) - 40
        if hpToRead > 0 {
            do { respHp = try await recvBytes(length: hpToRead) }
            catch { throw AFCError.operationFailed("\(opName): 讀回應頭負載失敗: \(error)") }
        }
        var respPayload = Data()
        let pToRead = Int(respEntireLen) - Int(respHpLen)
        if pToRead > 0 {
            do { respPayload = try await recvBytes(length: pToRead) }
            catch { throw AFCError.operationFailed("\(opName): 讀回應體失敗: \(error)") }
        }
        return (respOp, respHp, respPayload)
    }
    
    public func makeDirectory(path: String) async throws {
        let hp = path.data(using: .utf8)!
        let (op, hpResp, _) = try await transact(op: OP_MKDIR, headerPayload: hp, payload: Data(), opName: "MKDIR")
        guard op == OP_STATUS else {
            throw AFCError.operationFailed("MKDIR \(path) (op=\(String(format: "0x%02X", op)))")
        }
        let code: UInt64 = hpResp.count >= 8 ? hpResp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian } : .max
        if code != 0 { throw AFCError.operationFailed("MKDIR \(path) code=\(code)") }
    }

    private func makeParentDirs(for remotePath: String) async throws {
        var parts = remotePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        parts.removeLast()
        var cur = ""
        for p in parts {
            cur = cur.isEmpty ? p : cur + "/" + p
            try? await makeDirectory(path: cur)
        }
    }

    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        try await makeParentDirs(for: remotePath)
        var openHp = Data()
        var mode = FOPEN_WR.littleEndian
        openHp.append(Data(bytes: &mode, count: 8))
        openHp.append(remotePath.data(using: .utf8)!)
        let (openOp, openHpResp, _) = try await transact(op: OP_OPEN, headerPayload: openHp, payload: Data(), opName: "OPEN")
        guard openOp == OP_OPENRES, openHpResp.count >= 8 else {
            throw AFCError.openFailed("\(remotePath) (op=\(String(format: "0x%02X", openOp)))")
        }
        let handle = openHpResp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        let chunkSize = 32 * 1024
        var sent: Int64 = 0
        while sent < totalSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var writeHp = Data()
            var hLE = handle.littleEndian
            writeHp.append(Data(bytes: &hLE, count: 8))
            let (writeOp, writeHpResp, _) = try await transact(op: OP_WRITE, headerPayload: writeHp, payload: chunk, opName: "WRITE")
            let writeCode: UInt64 = writeHpResp.count >= 8 ? writeHpResp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian } : .max
            guard writeOp == OP_STATUS, writeCode == 0 else { throw AFCError.writeFailed }
            sent += Int64(chunk.count)
            progress(sent, totalSize)
        }
        var closeHp = Data()
        var hLE2 = handle.littleEndian
        closeHp.append(Data(bytes: &hLE2, count: 8))
        let (closeOp, _, _) = try await transact(op: OP_CLOSE, headerPayload: closeHp, payload: Data(), opName: "CLOSE")
        guard closeOp == OP_STATUS else { throw AFCError.closeFailed }
    }
    
    public func disconnect() {
        _ = channel?.close()
        channel = nil
        useSSL = false
    }
}

/// 負責緩存收到的字節，供 recvBytes 按需讀取
final class AFCResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var buffer = Data()
    private var waiters: [(Int, CheckedContinuation<Data, Error>)] = []
    private let lock = NSLock()
    private var closed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        self.lock.lock()
        if self.closed {
            self.lock.unlock()
            return
        }
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            self.buffer.append(contentsOf: bytes)
        }
        var ready: [(CheckedContinuation<Data, Error>, Data)] = []
        var i = 0
        while i < self.waiters.count {
            let (need, cont) = self.waiters[i]
            if self.buffer.count >= need {
                let out = Data(self.buffer.prefix(need))
                self.buffer.removeFirst(need)
                self.waiters.remove(at: i)
                ready.append((cont, out))
            } else {
                i += 1
            }
        }
        self.lock.unlock()
        for (cont, out) in ready {
            cont.resume(returning: out)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.failWaiters(AFCError.recvFailed("連接已關閉"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.failWaiters(error)
        context.close(promise: nil)
    }

    private func failWaiters(_ error: Error) {
        self.lock.lock()
        self.closed = true
        let ws = self.waiters
        self.waiters.removeAll()
        self.lock.unlock()
        for (_, cont) in ws {
            cont.resume(throwing: error)
        }
    }

    func read(length: Int) async throws -> Data {
        self.lock.lock()
        if self.closed {
            self.lock.unlock()
            throw AFCError.recvFailed("連接已關閉")
        }
        if self.buffer.count >= length {
            let out = Data(self.buffer.prefix(length))
            self.buffer.removeFirst(length)
            self.lock.unlock()
            return out
        }
        self.lock.unlock()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.lock.lock()
            if self.closed {
                self.lock.unlock()
                cont.resume(throwing: AFCError.recvFailed("連接已關閉"))
                return
            }
            if self.buffer.count >= length {
                let out = Data(self.buffer.prefix(length))
                self.buffer.removeFirst(length)
                self.lock.unlock()
                cont.resume(returning: out)
            } else {
                self.waiters.append((length, cont))
                self.lock.unlock()
            }
        }
    }
}

public enum AFCError: Error, LocalizedError {
    case notConnected
    case connectionFailed
    case sendFailed
    case recvFailed(String)
    case tlsFailed(String)
    case invalidResponse
    case incompleteData
    case operationFailed(String)
    case openFailed(String)
    case writeFailed
    case closeFailed
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "AFC 未連接"
        case .connectionFailed: return "AFC 連接失敗"
        case .sendFailed: return "AFC 發送失敗"
        case .recvFailed(let s): return "AFC 接收失敗: \(s)"
        case .tlsFailed(let s): return "AFC TLS 失敗: \(s)"
        case .invalidResponse: return "AFC 回應無效"
        case .incompleteData: return "AFC 數據不完整"
        case .operationFailed(let s): return s
        case .openFailed(let p): return "AFC 打開失敗: \(p)"
        case .writeFailed: return "AFC 寫入失敗"
        case .closeFailed: return "AFC 關閉失敗"
        }
    }
}
