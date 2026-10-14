import Foundation
import Security

/// Lockdown 協議客戶端（經 VPN 隧道連接設備）
/// 連接流程：明文 TCP → QueryType/ValidatePair/StartSession → TLS 升級（同一 socket）
public class LockdownClient {
    // SecureTransport 常量（Swift 未導出，用原始值）
    private static let errWouldBlock: OSStatus = -3101
    private static let errServerAuthCompleted: OSStatus = -9841
    private var socketFD: Int32 = -1
    private var sslContext: SSLContext?
    private var useSSL = false
    public let host: String
    public let port: UInt16
    private var sessionID: String?
    private var hostID: String?
    private var pairIdentity: SecIdentity?
    
    public init(host: String = "10.7.0.1", port: UInt16 = 62078) {
        self.host = host
        self.port = port
    }
    
    /// PEM 轉 DER
    static func derFromPEM(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        let b64 = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        return Data(base64Encoded: b64)
    }
    
    /// 從配對檔建立 SecIdentity（經 Keychain）
    /// 從配對檔建立 SecIdentity（經 Keychain）
    private func makeIdentity(hostCertPEM: String, hostKeyPEM: String) throws -> SecIdentity {
        guard let certDER = Self.derFromPEM(hostCertPEM) else { throw LockdownError.missingCredentials }
        guard let keyDER = Self.derFromPEM(hostKeyPEM) else { throw LockdownError.missingCredentials }
        
        let pemHeader = hostKeyPEM.components(separatedBy: .newlines).first(where: { $0.hasPrefix("-----") }) ?? "無PEM頭"
        let derHex = keyDER.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        
        // 驗證 PKCS#8 結構
        var diag: [String] = ["[\(pemHeader)] DER \(keyDER.count)字節 頭:\(derHex)"]
        guard let pkcs1Range = Self.validatePKCS8(keyDER, diag: &diag) else {
            throw LockdownError.tlsSetupFailed("私鑰結構驗證失敗\n" + diag.joined(separator: "\n"))
        }
        diag.append("PKCS#8 結構有效，內層 PKCS#1 \(pkcs1Range.count)字節")
        

        // 路線1: PKCS#1 內層直接 SecKeyCreateWithData
        let pkcs1Data = keyDER[pkcs1Range]
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var cfErr: Unmanaged<CFError>?
        if let secKey = SecKeyCreateWithData(pkcs1Data as CFData, keyAttrs as CFDictionary, &cfErr) {
            diag.append("PKCS#1 直接導入成功")
            return try Self.buildIdentity(secKey: secKey, certDER: certDER, diag: &diag)
        }
        diag.append("PKCS#1 導入失敗: \(cfErr?.takeRetainedValue().localizedDescription ?? "未知")")

        // 路線2: PKCS#8 完整 SecKeyCreateWithData
        if let secKey = SecKeyCreateWithData(keyDER as CFData, keyAttrs as CFDictionary, &cfErr) {
            diag.append("PKCS#8 直接導入成功")
            return try Self.buildIdentity(secKey: secKey, certDER: certDER, diag: &diag)
        }
        diag.append("PKCS#8 導入失敗: \(cfErr?.takeRetainedValue().localizedDescription ?? "未知")")

        // 路線3: SecItemAdd 存 PKCS#8 再取回
        let tagData = "PaxStorePairing".data(using: .utf8)!
        let delKey: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData]
        SecItemDelete(delKey as CFDictionary)
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecValueData as String: keyDER,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemAdd(addKey as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        guard status == errSecSuccess else {
            throw LockdownError.tlsSetupFailed("私鑰存 Keychain 失敗: \(status)\n" + diag.joined(separator: "\n"))
        }
        diag.append("私鑰已存 Keychain")
        let getKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecReturnRef as String: true,
        ]
        var keyItem: CFTypeRef?
        status = SecItemCopyMatching(getKey as CFDictionary, &keyItem)
        guard status == errSecSuccess, let keyItem = keyItem else {
            throw LockdownError.tlsSetupFailed("私鑰取回失敗 status=\(status) itemNil=\(keyItem == nil)\n" + diag.joined(separator: "\n"))
        }
        diag.append("Keychain 取回成功")
        let secKey = keyItem as! SecKey
        return try Self.buildIdentity(secKey: secKey, certDER: certDER, diag: &diag)
    }

    /// 用 SecKey + 證書 DER 組裝 SecIdentity（存 Keychain 再取）
    private static func buildIdentity(secKey: SecKey, certDER: Data, diag: inout [String]) throws -> SecIdentity {
        let delCert: [String: Any] = [kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "PaxStorePairing"]
        SecItemDelete(delCert as CFDictionary)
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw LockdownError.tlsSetupFailed("證書解析失敗")
        }
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "PaxStorePairing".data(using: .utf8)!,
            kSecValueRef as String: secKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemAdd(addKey as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("私鑰存 Keychain 失敗: \(status)") }
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "PaxStorePairing",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        status = SecItemAdd(addCert as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("證書存 Keychain 失敗: \(status)") }
        diag.append("證書已存 Keychain")
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "PaxStorePairing",
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            let q2: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecValueRef as String: cert,
                kSecReturnRef as String: true,
            ]
            status = SecItemCopyMatching(q2 as CFDictionary, &item)
        }
        guard status == errSecSuccess, let identity = item as! SecIdentity? else {
            throw LockdownError.tlsSetupFailed("取 SecIdentity 失敗: \(status)\n" + diag.joined(separator: "\n"))
        }
        diag.append("SecIdentity 組裝成功")
        return identity
    }
    
    /// 驗證 PKCS#8 結構，返回內層 PKCS#1 的範圍
    static func validatePKCS8(_ data: Data, diag: inout [String]) -> Range<Int>? {
        let bytes = [UInt8](data)
        var pos = 0
        var intBytes: [Int: [UInt8]] = [:]
        
        // 外層 SEQUENCE
        guard pos < bytes.count && bytes[pos] == 0x30 else { diag.append("外層不是 SEQUENCE"); return nil }
        pos += 1
        guard let (seqLen, seqLenBytes) = readDERLength(bytes, pos) else { diag.append("外層長度解析失敗"); return nil }
        pos += seqLenBytes
        if seqLen != bytes.count - pos {
            diag.append("外層長度不匹配: 聲稱\(seqLen)，實際\(bytes.count - pos)")
            return nil
        }
        diag.append("外層 SEQUENCE 長度\(seqLen) ✓")
        
        // INTEGER 0 (version)
        guard pos + 3 <= bytes.count && bytes[pos] == 0x02 && bytes[pos+1] == 0x01 && bytes[pos+2] == 0x00 else {
            diag.append("版本不是 INTEGER 0"); return nil
        }
        pos += 3
        diag.append("版本 INTEGER 0 ✓")
        
        // AlgorithmIdentifier SEQUENCE
        guard pos < bytes.count && bytes[pos] == 0x30 else { diag.append("算法標識不是 SEQUENCE"); return nil }
        pos += 1
        guard let (algLen, algLenBytes) = readDERLength(bytes, pos) else { diag.append("算法長度解析失敗"); return nil }
        pos += algLenBytes
        let algEnd = pos + algLen
        // OID rsaEncryption
        let expectedOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        guard pos + expectedOID.count <= bytes.count && Array(bytes[pos..<(pos+expectedOID.count)]) == expectedOID else {
            diag.append("OID 不是 rsaEncryption"); return nil
        }
        pos += expectedOID.count
        // NULL
        guard pos + 2 <= bytes.count && bytes[pos] == 0x05 && bytes[pos+1] == 0x00 else {
            diag.append("算法參數不是 NULL"); return nil
        }
        pos += 2
        if pos != algEnd { diag.append("算法標識有多餘字節"); return nil }
        diag.append("算法 rsaEncryption ✓")
        
        // OCTET STRING (內層 PKCS#1)
        guard pos < bytes.count && bytes[pos] == 0x04 else { diag.append("私鑰不是 OCTET STRING"); return nil }
        pos += 1
        guard let (octLen, octLenBytes) = readDERLength(bytes, pos) else { diag.append("OCTET長度解析失敗"); return nil }
        pos += octLenBytes
        let octEnd = pos + octLen
        guard octEnd == bytes.count else {
            diag.append("OCTET STRING 長度不匹配: 聲稱\(octLen)，剩餘\(bytes.count - pos)")
            return nil
        }
        diag.append("OCTET STRING 長度\(octLen) ✓")
        
        // 驗證內層是 PKCS#1 (SEQUENCE)
        guard pos < bytes.count && bytes[pos] == 0x30 else { diag.append("內層不是 SEQUENCE"); return nil }
        let innerSeqStart = pos
        pos += 1
        guard let (innerLen, innerLenBytes) = readDERLength(bytes, pos) else { diag.append("內層長度解析失敗"); return nil }
        pos += innerLenBytes
        let innerEnd = pos + innerLen
        guard innerEnd == octEnd else {
            diag.append("內層長度不匹配: 聲稱\(innerLen)，實際\(octEnd - pos)")
            return nil
        }
        diag.append("內層 SEQUENCE 長度\(innerLen) ✓")
        
        // PKCS#1 應有 9 個 INTEGER: version, n, e, d, p, q, dp, dq, qinv
        let names = ["版本", "n(模數)", "e(公鑰指數)", "d(私鑰指數)", "p", "q", "dp", "dq", "qinv"]
        var intCount = 0
        var nBits = 0
        while pos < innerEnd && intCount < 9 {
            guard pos < bytes.count && bytes[pos] == 0x02 else {
                diag.append("第\(intCount)個不是 INTEGER (tag=\(pos < bytes.count ? String(format:"%02X", bytes[pos]) : "越界"))")
                return nil
            }
            pos += 1
            guard let (ilen, ilenBytes) = readDERLength(bytes, pos) else {
                diag.append("第\(intCount)個 INTEGER 長度解析失敗"); return nil
            }
            pos += ilenBytes
            guard pos + ilen <= bytes.count else {
                diag.append("第\(intCount)個 INTEGER 超出範圍"); return nil
            }
            // 檢查 INTEGER 是否為負數（首字節最高位為1且無前導零）
            let firstByte = bytes[pos]
            let isNegative = (firstByte & 0x80) != 0
            let name = intCount < names.count ? names[intCount] : "未知"
            if intCount == 1 { nBits = ilen * 8 }  // n 的字節數估算位數
            if isNegative {
                diag.append("第\(intCount)個 [\(name)] 長度\(ilen) 為負數 ✗")
            } else {
                diag.append("第\(intCount)個 [\(name)] 長度\(ilen) ✓")
            }
            intBytes[intCount] = Array(bytes[pos..<(pos+ilen)])
            pos += ilen
            intCount += 1
        }
        if intCount != 9 {
            diag.append("INTEGER 個數不對: \(intCount) (應為9)")
            return nil
        }
        if pos != innerEnd {
            diag.append("內層有多餘字節: \(innerEnd - pos)")
            return nil
        }
        diag.append("PKCS#1 9個INTEGER齊全，n約\(nBits)位 ✓")
        
        // 驗算 p*q 是否等於 n（揪出 Base64 複製損壞導致的數學無效）
        if let pB = intBytes[4], let qB = intBytes[5], let nB = intBytes[1] {
            if bigMulEquals(pB, qB, nB) {
                diag.append("p×q=n 數學驗算通過 ✓")
            } else {
                diag.append("p×q≠n 數學驗算失敗 ✗（私鑰參數已損壞，需重新生成配對檔）")
            }
        }
        
        return innerSeqStart..<octEnd
    }
    
    /// 大數乘法驗算 p*q==n（字節均為大端序，可能含前導零）
    static func bigMulEquals(_ pBytes: [UInt8], _ qBytes: [UInt8], _ nBytes: [UInt8]) -> Bool {
        // 去前導零，轉小端序 UInt64 數組
        func toWords(_ b: [UInt8]) -> [UInt64] {
            var bytes = b
            while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
            var words: [UInt64] = []
            var i = bytes.count
            while i > 0 {
                let start = max(0, i - 8)
                var w: UInt64 = 0
                for j in start..<i { w = (w << 8) | UInt64(bytes[j]) }
                words.append(w)
                i = start
            }
            return words
        }
        let pw = toWords(pBytes), qw = toWords(qBytes)
        var result = [UInt64](repeating: 0, count: pw.count + qw.count + 1)
        for i in 0..<pw.count {
            var carryLo: UInt64 = 0
            var carryHi: UInt64 = 0  // 0 或 1，處理 carry = 2^64 的極端情況
            for j in 0..<qw.count {
                // total = result[i+j] + pw[i]*qw[j] + (carryHi*2^64+carryLo)
                let (phi, plo) = pw[i].multipliedFullWidth(by: qw[j])
                let (s1, o1) = result[i+j].addingReportingOverflow(plo)
                let (s2, o2) = s1.addingReportingOverflow(carryLo)
                // carryHi*2^64 加到 s2 上：相當於再進位 carryHi
                let (s3, o3) = s2.addingReportingOverflow(carryHi)
                result[i+j] = s3
                // 新 carry = phi + o1 + o2 + o3（< 2^64+2，用兩字存）
                let (t1, to1) = phi.addingReportingOverflow(o1 ? 1 : 0)
                let (t2, to2) = t1.addingReportingOverflow(o2 ? 1 : 0)
                let (t3, to3) = t2.addingReportingOverflow(o3 ? 1 : 0)
                carryLo = t3
                carryHi = (to1 ? 1 : 0) + (to2 ? 1 : 0) + (to3 ? 1 : 0)
            }
            // 把 carry 寫回 result[i+count...]（最多兩字）
            var k = i + qw.count
            var clo = carryLo, chi = carryHi
            while (clo > 0 || chi > 0) && k < result.count {
                let (s1, o1) = result[k].addingReportingOverflow(clo)
                let (s2, o2) = s1.addingReportingOverflow(chi)
                result[k] = s2
                clo = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                chi = 0  // 進位鏈不會再產生 carryHi
                k += 1
            }
        }
        // 轉回大端序字節，去前導零後比較
        var outBytes: [UInt8] = []
        for w in result.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                outBytes.append(UInt8((w >> shift) & 0xFF))
            }
        }
        while outBytes.count > 1 && outBytes[0] == 0 { outBytes.removeFirst() }
        var nNorm = nBytes
        while nNorm.count > 1 && nNorm[0] == 0 { nNorm.removeFirst() }
        return outBytes == nNorm
    }
    
    /// 讀取 DER 長度編碼，返回 (長度, 佔用字節數)
    static func readDERLength(_ bytes: [UInt8], _ pos: Int) -> (Int, Int)? {
        guard pos < bytes.count else { return nil }
        let b = bytes[pos]
        if b < 0x80 { return (Int(b), 1) }
        let count = Int(b & 0x7F)
        guard count > 0 && count <= 4 && pos + 1 + count <= bytes.count else { return nil }
        var len = 0
        for i in 0..<count {
            len = (len << 8) | Int(bytes[pos + 1 + i])
        }
        return (len, 1 + count)
    }
    
    /// 使用配對檔建立 TLS 連接並完成 lockdown 握手
    public func connect(pairingFileURL: URL) async throws {
        guard let plist = NSDictionary(contentsOf: pairingFileURL) as? [String: Any] else {
            throw LockdownError.invalidPairingFile
        }
        guard let hostCertPEM = (plist["HostCertificate"] as? Data).flatMap({ String(data: $0, encoding: .utf8) }) ?? (plist["HostCertificate"] as? String),
              let hostKeyPEM = (plist["HostPrivateKey"] as? Data).flatMap({ String(data: $0, encoding: .utf8) }) ?? (plist["HostPrivateKey"] as? String),
              let hostID = plist["HostID"] as? String else {
            throw LockdownError.missingCredentials
        }
        self.hostID = hostID

        // 階段1: 明文 TCP 連接
        try tcpConnect()

        // 階段2: 明文握手（對照 idevice 源碼：QueryType → StartSession → TLS，無 ValidatePair）
        // 配對驗證靠 TLS 階段的客戶端證書完成
        let qt: [String: Any]
        do {
            qt = try await sendPlist(["Label": "PaxStore", "Request": "QueryType"])
        } catch {
            throw LockdownError.handshakeFailed("QueryType 階段連接斷開: \(error)")
        }
        guard (qt["Type"] as? String) == "com.apple.mobile.lockdown" else {
            throw LockdownError.handshakeFailed("QueryType 回應異常")
        }
        // 校驗配對檔 UDID 是否與設備一致
        if let deviceUDID = qt["UniqueDeviceID"] as? String,
           let fileUDID = plist["UDID"] as? String,
           deviceUDID.lowercased() != fileUDID.lowercased() {
            throw LockdownError.handshakeFailed("配對檔 UDID 與設備不符：配對檔=\(fileUDID)，設備=\(deviceUDID)，請導入正確的配對檔")
        }
        // StartSession：帶 HostID + SystemBUID
        var ssReq: [String: Any] = ["Label": "PaxStore", "Request": "StartSession", "HostID": hostID]
        if let buid = plist["SystemBUID"] as? String { ssReq["SystemBUID"] = buid }
        let ss: [String: Any]
        do {
            ss = try await sendPlist(ssReq)
        } catch {
            throw LockdownError.handshakeFailed("StartSession 階段連接斷開: \(error)")
        }
        guard (ss["EnableSessionSSL"] as? Bool) == true else {
            throw LockdownError.handshakeFailed("StartSession 失敗: \(ss)")
        }
        self.sessionID = ss["SessionID"] as? String

        // 階段3: 在同一條 TCP 上升級 TLS（客戶端證書認證）
        let identity = try makeIdentity(hostCertPEM: hostCertPEM, hostKeyPEM: hostKeyPEM)
        self.pairIdentity = identity
        try upgradeToTLS(identity: identity)
        self.useSSL = true
    }

    // MARK: - BSD Socket 明文層

    private func tcpConnect() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LockdownError.tlsSetupFailed("socket 創建失敗") }
        var flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc < 0 && errno != EINPROGRESS {
            close(fd)
            throw LockdownError.tlsSetupFailed("TCP 連接失敗: \(String(cString: strerror(errno)))")
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, 10000)
        if pr <= 0 {
            close(fd)
            throw LockdownError.tlsSetupFailed(pr == 0 ? "TCP 連接超時（10秒）" : "poll 失敗")
        }
        var soErr: Int32 = 0
        var soErrLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen)
        if soErr != 0 {
            close(fd)
            throw LockdownError.tlsSetupFailed("TCP 連接失敗: \(String(cString: strerror(soErr)))")
        }
        flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        self.socketFD = fd
    }

    private func sendRaw(_ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { throw LockdownError.tlsSetupFailed("空數據") }
            while sent < data.count {
                let n = send(socketFD, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { throw LockdownError.tlsSetupFailed("發送失敗: \(String(cString: strerror(errno)))") }
                sent += n
            }
        }
    }

    private func recvRaw(length: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(length)
        var buf = [UInt8](repeating: 0, count: min(length, 65536))
        while result.count < length {
            let toRead = min(buf.count, length - result.count)
            let n = recv(socketFD, &buf, toRead, 0)
            if n <= 0 { throw LockdownError.tlsSetupFailed("明文階段連接被設備斷開 (recv=\(n), errno=\(errno))") }
            result.append(buf, count: n)
        }
        return result
    }

    // MARK: - TLS 升級（SecureTransport）

    private static let sslReadFunc: SSLReadFunc = { connection, data, dataLength in
        let fd = Int32(Int(bitPattern: connection))
        let n = recv(fd, data, dataLength.pointee, 0)
        if n > 0 {
            dataLength.pointee = n
            return errSecSuccess
        } else if n == 0 {
            dataLength.pointee = 0
            return errSecIO
        } else {
            dataLength.pointee = 0
            return (errno == EAGAIN || errno == EWOULDBLOCK) ? LockdownClient.errWouldBlock : errSecIO
        }
    }

    private static let sslWriteFunc: SSLWriteFunc = { connection, data, dataLength in
        let fd = Int32(Int(bitPattern: connection))
        let n = send(fd, data, dataLength.pointee, 0)
        if n > 0 {
            dataLength.pointee = n
            return errSecSuccess
        } else {
            dataLength.pointee = 0
            return (errno == EAGAIN || errno == EWOULDBLOCK) ? LockdownClient.errWouldBlock : errSecIO
        }
    }

    private func upgradeToTLS(identity: SecIdentity) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw LockdownError.tlsSetupFailed("SSLContext 創建失敗")
        }
        self.sslContext = ctx
        let connRef = unsafeBitCast(Int(socketFD), to: SSLConnectionRef.self)
        var status = SSLSetConnection(ctx, connRef)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetConnection: \(status)") }
        status = SSLSetIOFuncs(ctx, Self.sslReadFunc, Self.sslWriteFunc)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetIOFuncs: \(status)") }
        // 強制 TLS 1.2（iOS 15 lockdownd 不認 TLS 1.3 的 ClientHello）
        status = SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetProtocolVersionMin: \(status)") }
        status = SSLSetProtocolVersionMax(ctx, .tlsProtocol12)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetProtocolVersionMax: \(status)") }
        // 客戶端身份（證書+私鑰）
        status = SSLSetCertificate(ctx, [identity] as CFArray)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetCertificate: \(status)") }
        // SNI（AFC 那邊用 "Device"，這裡也試試）
        status = SSLSetPeerDomainName(ctx, "Device", 6)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetPeerDomainName: \(status)") }
        // 不驗證服務器（lockdownd 自簽名），但要在 server auth 處手動放行
        status = SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("SSLSetSessionOption: \(status)") }
        // 握手循環
        repeat {
            status = SSLHandshake(ctx)
            if status == Self.errServerAuthCompleted {
                // 放行自簽名服務器證書，繼續握手
                continue
            }
        } while status == Self.errWouldBlock || status == Self.errServerAuthCompleted
        guard status == errSecSuccess else {
            throw LockdownError.tlsSetupFailed("TLS 握手失敗: \(status)")
        }
    }

    private func sslWrite(_ data: Data) throws {
        guard let ctx = sslContext else { throw LockdownError.notConnected }
        var sent = 0
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { throw LockdownError.tlsSetupFailed("空數據") }
            while sent < data.count {
                var processed = 0
                let status = SSLWrite(ctx, base.advanced(by: sent), data.count - sent, &processed)
                if status != errSecSuccess && status != Self.errWouldBlock {
                    throw LockdownError.tlsSetupFailed("SSLWrite: \(status)")
                }
                sent += processed
                if processed == 0 && status == Self.errWouldBlock { continue }
            }
        }
    }

    private func sslRead(length: Int) throws -> Data {
        guard let ctx = sslContext else { throw LockdownError.notConnected }
        var result = Data()
        result.reserveCapacity(length)
        var buf = [UInt8](repeating: 0, count: min(length, 16384))
        while result.count < length {
            let toRead = min(buf.count, length - result.count)
            var processed = 0
            let status = SSLRead(ctx, &buf, toRead, &processed)
            if status != errSecSuccess && status != Self.errWouldBlock {
                throw LockdownError.tlsSetupFailed("SSLRead: \(status)")
            }
            if processed > 0 {
                result.append(buf, count: processed)
            } else if status != Self.errWouldBlock {
                throw LockdownError.tlsSetupFailed("TLS 階段連接被設備斷開 (SSLRead status=\(status))")
            }
        }
        return result
    }
    
    /// 發送 plist 消息並接收回應
    public func sendPlist(_ dict: [String: Any]) async throws -> [String: Any] {
        guard socketFD >= 0 else { throw LockdownError.notConnected }
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        var length = UInt32(plistData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let payload = lengthData + plistData
        // 同步 IO 放在後台線程，避免阻塞
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    if self.useSSL {
                        try self.sslWrite(payload)
                    } else {
                        try self.sendRaw(payload)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let lengthResponse = try await receive(length: 4)
        let responseLength = lengthResponse.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let plistResponse = try await receive(length: Int(responseLength))
        guard let responseDict = try PropertyListSerialization.propertyList(from: plistResponse, options: [], format: nil) as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        return responseDict
    }

    private func receive(length: Int) async throws -> Data {
        guard socketFD >= 0 else { throw LockdownError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let data: Data
                    if self.useSSL {
                        data = try self.sslRead(length: length)
                    } else {
                        data = try self.recvRaw(length: length)
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 啟動服務
    public func startService(_ serviceName: String) async throws -> (port: UInt16, sslEnabled: Bool) {
        // 對照 idevice：只取 Port，不檢查 Result
        var req: [String: Any] = ["Request": "StartService", "Service": serviceName]
        if let sid = sessionID { req["SessionID"] = sid }
        let response = try await sendPlist(req)
        if let err = response["Error"] as? String {
            throw LockdownError.handshakeFailed("StartService \(serviceName) 報錯: \(err)")
        }
        guard let portRaw = response["Port"] as? Int ?? (response["Port"] as? UInt16).map({ Int($0) }) else {
            throw LockdownError.serviceStartFailed(serviceName)
        }
        let sslEnabled = (response["EnableServiceSSL"] as? Bool) ?? false
        return (UInt16(portRaw), sslEnabled)
    }
    
    /// 配對用的客戶端身份（給需要 SSL 的服務用）
    public var identity: SecIdentity? { pairIdentity }
    
    public func disconnect() {
        if let ctx = sslContext {
            SSLClose(ctx)
            self.sslContext = nil
        }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        useSSL = false
    }
}

public enum LockdownError: Error, LocalizedError {
    case invalidPairingFile
    case missingCredentials
    case notConnected
    case connectionCancelled
    case invalidResponse
    case incompleteData
    case serviceStartFailed(String)
    case tlsSetupFailed(String)
    case handshakeFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPairingFile: return "配對檔無效"
        case .missingCredentials: return "配對檔缺少證書"
        case .notConnected: return "未連接"
        case .connectionCancelled: return "連接已取消"
        case .invalidResponse: return "回應無效"
        case .incompleteData: return "數據不完整"
        case .serviceStartFailed(let s): return "啟動服務失敗: \(s)"
        case .tlsSetupFailed(let s): return "TLS 設置失敗: \(s)"
        case .handshakeFailed(let s): return "握手失敗: \(s)"
        }
    }
}
