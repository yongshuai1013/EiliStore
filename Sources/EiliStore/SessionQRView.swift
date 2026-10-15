import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation

/// Session 二維碼導出/導入
public struct SessionQRView: View {
    @State private var qrImage: UIImage?
    @State private var showScanner = false
    @State private var message = ""
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 20) {
            if let img = qrImage {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                Text("掃描此二維碼以導入 Session")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("尚未生成二維碼")
                    .foregroundColor(.secondary)
            }
            
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            HStack(spacing: 16) {
                Button("生成二維碼") {
                    generateQR()
                }
                .buttonStyle(.borderedProminent)
                
                Button("掃描二維碼") {
                    showScanner = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .sheet(isPresented: $showScanner) {
            QRScannerView { result in
                importSession(from: result)
            }
        }
    }
    
    private func generateQR() {
        // 從 Keychain 讀取 session
        guard let sessionData = KeychainHelper.load(forKey: "paxstore.auth.session") else {
            message = "沒有已保存的 Session"
            return
        }
        // Base64 編碼（QR 內容必須是文本）
        let b64 = sessionData.base64EncodedString()
        // 生成二維碼
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(b64.utf8)
        filter.correctionLevel = "M"
        if let output = filter.outputImage,
           let cgimg = context.createCGImage(output, from: output.extent) {
            qrImage = UIImage(cgImage: cgimg)
            message = "二維碼已生成（\(b64.count) 字符）"
        } else {
            message = "生成失敗"
        }
    }
    
    private func importSession(from qrText: String) {
        // QR 內容是 base64 的 session data
        guard let data = Data(base64Encoded: qrText) else {
            message = "二維碼格式錯誤"
            return
        }
        // 寫入 Keychain
        if KeychainHelper.save(data, forKey: "paxstore.auth.session") {
            message = "Session 導入成功！"
            showScanner = false
        } else {
            message = "導入失敗"
        }
    }
}

/// 二維碼掃描器
struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String) -> Void
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        let session = AVCaptureSession()
        
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return vc
        }
        session.addInput(input)
        
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = vc.view.bounds
        preview.videoGravity = .resizeAspectFill
        vc.view.layer.addSublayer(preview)
        
        context.coordinator.session = session
        session.startRunning()
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, dismiss: { dismiss() })
    }
    
    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onResult: (String) -> Void
        var dismiss: () -> Void
        var session: AVCaptureSession?
        
        init(onResult: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
            self.onResult = onResult
            self.dismiss = dismiss
        }
        
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
               let str = obj.stringValue {
                session?.stopRunning()
                onResult(str)
            }
        }
    }
}
