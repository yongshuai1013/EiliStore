import SwiftUI
import SideSign
import CodeSignKit
import CryptoKit

/// 證書詳情頁（照 PaxStore 搬）
struct CertificateDetailView: View {
    let cert: SideSign.X509Certificate
    let hasPrivateKey: Bool
    
    @State private var showPrivateKey = false
    @State private var privateKeyData: Data?
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var exportError: String?
    @State private var showExportOptions = false
    
    var body: some View {
        List {
            // MARK: - Developer Portal Info
            Section(header: Text("Developer Portal Info")) {
                if let id = cert.identifier {
                    CopyableRow(label: "Certificate ID", value: id)
                }
                if let type = cert.certificateTypeName ?? cert.certificateType {
                    DetailRow(label: "Certificate Type", value: type)
                }
                if let platform = cert.platformName ?? cert.platform {
                    DetailRow(label: "Platform", value: platform)
                }
                if let machineID = cert.machineIdentifier {
                    DetailRow(label: "Machine ID", value: machineID)
                }
                if let owner = cert.ownerName {
                    DetailRow(label: "Created By", value: owner)
                }
                if let email = cert.requesterEmail {
                    DetailRow(label: "Requester Email", value: email)
                }
            }
            
            // MARK: - X.509 Fields
            Section(header: Text("X.509 FIELDS")) {
                DetailRow(label: "Version", value: "3")
                DetailRow(label: "Subject", value: formatDN(cert.subjectDER))
                DetailRow(label: "Issuer", value: formatDN(cert.issuerDER))
                DetailRow(label: "Serial Number (hex)", value: "0x" + cert.serialNumberHex)
                if let dec = cert.serialNumDecimal {
                    DetailRow(label: "Serial Number (dec)", value: dec)
                }
            }
            
            // MARK: - Validity Period
            Section(header: Text("VALIDITY PERIOD")) {
                DetailRow(label: "Valid From", value: formatDateTime(cert.creationDate))
                DetailRow(label: "Valid Until", value: formatDateTime(cert.expiryDate))
                
                let progress = validityProgress()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Validity Progress")
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .foregroundColor(.gray)
                    }
                    ProgressView(value: progress)
                }
                .padding(.vertical, 2)
                
                let days = validityDays()
                DetailRow(
                    label: "Validity Days",
                    value: "Total: \(days.total), Elapsed: \(days.elapsed), Remaining: \(days.remaining)"
                )
            }
            
            // MARK: - Signature & Public Key Details
            Section(header: Text("SIGNATURE & PUBLIC KEY DETAILS")) {
                DetailRow(label: "Public Key", value: publicKeyAlgorithm())
                DetailRow(label: "Signature Algorithm", value: signatureAlgorithm())
                CopyableRow(label: "SHA-1 Fingerprint", value: formatFingerprint(cert.sha1Fingerprint))
                CopyableRow(label: "SHA-256 Fingerprint", value: formatFingerprint(sha256Fingerprint()))
            }
            
            // MARK: - Cryptographic Keys
            Section(header: Text("CRYPTOGRAPHIC KEYS")) {
                DetailRow(label: "Has Private Key", value: hasPrivateKey ? "Yes" : "No")
                
                if hasPrivateKey {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Private Key Data")
                            Spacer()
                            Button(action: { showPrivateKey.toggle() }) {
                                Image(systemName: showPrivateKey ? "eye.slash" : "eye")
                            }
                            Button(action: {
                                if let data = privateKeyData {
                                    UIPasteboard.general.string = data.base64EncodedString()
                                }
                            }) {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                        if showPrivateKey, let data = privateKeyData {
                            Text(data.base64EncodedString())
                                .font(.caption)
                                .foregroundColor(.gray)
                                .textSelection(.enabled)
                        } else {
                            Text(String(repeating: "•", count: 30))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 2)
                }
                
                if let der = cert.data {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Certificate PEM Data")
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = pemString(from: der)
                            }) {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                        Text(pemBody(from: der))
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Certificate Details")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("導出") {
                    showExportOptions = true
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ShareSheet(url: url)
            }
        }
        .alert("導出失敗", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("確定", role: .cancel) { }
        } message: {
            Text(exportError ?? "")
        }
        .actionSheet(isPresented: $showExportOptions) {
            ActionSheet(
                title: Text("選擇導出格式"),
                buttons: exportSheetButtons()
            )
        }
        .onAppear {
            if hasPrivateKey {
                privateKeyData = PaxSigningService.shared.loadActiveCertificate()?.privateKey
            }
        }
    }
    
    // MARK: - Export

    private func exportSheetButtons() -> [ActionSheet.Button] {
        var buttons: [ActionSheet.Button] = [
            .default(Text("證書 (.cer)")) { exportCertificate() }
        ]
        if hasPrivateKey {
            buttons.append(.default(Text("P12 含私鑰 (.p12)")) { exportP12() })
        }
        buttons.append(.default(Text("下載描述檔 (.mobileprovision)")) { showProfileDownload = true })
        buttons.append(.cancel(Text("取消")))
        return buttons
    }

    private func exportCertificate() {
        exportError = nil
        guard let der = cert.data else {
            exportError = "證書數據為空(nil)，無法導出。該證書可能不是本機創建，Apple 未返回證書內容。"
            return
        }
        guard !der.isEmpty else {
            exportError = "證書數據為空(0字節)，無法導出"
            return
        }
        let filename = "certificate-\(cert.serialNumberHex).cer"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try der.write(to: url)
            exportURL = url
            showShare = true
        } catch {
            exportError = "寫入失敗：\(error.localizedDescription)"
        }
    }

    private func exportP12() {
        exportError = nil
        guard let keyStore = PaxSigningService.shared.loadActiveCertificate() else {
            exportError = "本地沒有該證書的私鑰，無法導出 P12"
            return
        }
        guard keyStore.certificate.serialNumberHex == cert.serialNumberHex else {
            exportError = "該證書不是本地激活證書，無私鑰可導出"
            return
        }
        do {
            let p12Data = try keyStore.exportP12()
            let filename = "certificate-\(cert.serialNumberHex).p12"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try p12Data.write(to: url)
            exportURL = url
            showShare = true
        } catch {
            exportError = "導出 P12 失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - Helpers
    
    private func formatDateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy 'at' h:mm:ss a"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: date)
    }
    
    private func validityProgress() -> Double {
        let now = Date()
        let start = cert.creationDate
        let end = cert.expiryDate
        guard end > start else { return 0 }
        if now <= start { return 0 }
        if now >= end { return 1 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
    
    private func validityDays() -> (total: Int, elapsed: Int, remaining: Int) {
        let now = Date()
        let start = cert.creationDate
        let end = cert.expiryDate
        let total = max(0, Int(end.timeIntervalSince(start) / 86400))
        let elapsed = max(0, min(total, Int(now.timeIntervalSince(start) / 86400)))
        let remaining = max(0, total - elapsed)
        return (total, elapsed, remaining)
    }
    
    private func formatFingerprint(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    private func sha256Fingerprint() -> Data {
        guard let der = cert.data else { return Data() }
        return Data(SHA256.hash(data: der))
    }
    
    private func pemString(from der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----"
    }
    
    private func pemBody(from der: Data) -> String {
        der.base64EncodedString().prefix(60) + "..."
    }
    
    /// 解析 DN DER 為 "Name=value, Name=value" 格式
    private func formatDN(_ der: Data) -> String {
        // DN = SEQUENCE of RDN (SET of AttributeTypeAndValue)
        guard let tlv = ASN1Helper.parseTLV(from: der), tlv.tag == 0x30 else {
            return cert.subjectSummary
        }
        let rdns = ASN1Helper.parseSequenceChildren(from: tlv.value)
        var parts: [String] = []
        for rdn in rdns {
            // RDN is a SET containing AttributeTypeAndValue sequences
            let atvs: [(tag: UInt8, value: Data, rawDER: Data)]
            if rdn.tag == 0x31 {
                atvs = ASN1Helper.parseSequenceChildren(from: rdn.value)
            } else {
                atvs = [rdn]
            }
            for atv in atvs {
                guard atv.tag == 0x30 else { continue }
                let items = ASN1Helper.parseSequenceChildren(from: atv.value)
                guard items.count >= 2 else { continue }
                // items[0] is OID (tag 0x06), items[1] is value
                let oidString = decodeOID(items[0].value)
                let name = oidName(oidString)
                let value = String(data: items[1].value, encoding: .utf8)
                    ?? String(data: items[1].value, encoding: .ascii)
                    ?? ""
                parts.append("\(name)=\(value)")
            }
        }
        return parts.isEmpty ? cert.subjectSummary : parts.joined(separator: ", ")
    }
    
    private func decodeOID(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var numbers: [Int] = []
        let first = Int(data[0])
        numbers.append(first / 40)
        numbers.append(first % 40)
        var value = 0
        for byte in data.dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if (byte & 0x80) == 0 {
                numbers.append(value)
                value = 0
            }
        }
        return numbers.map(String.init).joined(separator: ".")
    }
    
    private func oidName(_ oid: String) -> String {
        switch oid {
        case "2.5.4.3": return "Common Name"
        case "2.5.4.4": return "Surname"
        case "2.5.4.5": return "Serial Number"
        case "2.5.4.6": return "Country"
        case "2.5.4.7": return "Locality"
        case "2.5.4.8": return "State"
        case "2.5.4.10": return "Organization"
        case "2.5.4.11": return "Organizational Unit"
        case "2.5.4.12": return "Title"
        case "2.5.4.42": return "Given Name"
        case "1.2.840.113549.1.9.1": return "Email"
        default: return oid
        }
    }
    
    private func publicKeyAlgorithm() -> String {
        // subjectPublicKeyInfo = SEQUENCE { algorithm SEQUENCE { OID }, publicKey BIT STRING }
        let spki = cert.subjectPublicKeyInfoDER
        guard let tlv = ASN1Helper.parseTLV(from: spki), tlv.tag == 0x30 else { return "Unknown" }
        let children = ASN1Helper.parseSequenceChildren(from: tlv.value)
        guard let algSeq = children.first, algSeq.tag == 0x30 else { return "Unknown" }
        let algItems = ASN1Helper.parseSequenceChildren(from: algSeq.value)
        guard let oidItem = algItems.first, oidItem.tag == 0x06 else { return "Unknown" }
        let oid = decodeOID(oidItem.value)
        switch oid {
        case "1.2.840.113549.1.1.1": return "RSA"
        case "1.2.840.10045.2.1": return "EC"
        default: return oid
        }
    }
    
    private func signatureAlgorithm() -> String {
        // Certificate = SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        guard let der = cert.data,
              let tlv = ASN1Helper.parseTLV(from: der), tlv.tag == 0x30 else { return "Unknown" }
        let children = ASN1Helper.parseSequenceChildren(from: tlv.value)
        guard children.count >= 2 else { return "Unknown" }
        let sigAlg = children[1]
        guard sigAlg.tag == 0x30 else { return "Unknown" }
        let algItems = ASN1Helper.parseSequenceChildren(from: sigAlg.value)
        guard let oidItem = algItems.first, oidItem.tag == 0x06 else { return "Unknown" }
        let oid = decodeOID(oidItem.value)
        switch oid {
        case "1.2.840.113549.1.1.11": return "SHA-256 with RSA"
        case "1.2.840.113549.1.1.12": return "SHA-384 with RSA"
        case "1.2.840.113549.1.1.13": return "SHA-512 with RSA"
        case "1.2.840.113549.1.1.5": return "SHA-1 with RSA"
        case "1.2.840.113549.1.1.4": return "MD5 with RSA"
        case "1.2.840.10045.4.3.2": return "ECDSA with SHA-256"
        case "1.2.840.10045.4.3.3": return "ECDSA with SHA-384"
        default: return oid
        }
    }
}

// MARK: - Subviews

private struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.body)
        }
        .padding(.vertical, 2)
    }
}

private struct CopyableRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = value
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
            }
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

