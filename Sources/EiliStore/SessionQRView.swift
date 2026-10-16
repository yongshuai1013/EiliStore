import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation
import SideSign
import UIKit

/// Session 二維碼導出/導入
public struct SessionQRView: View {
    @State private var qrImage: UIImage?
    @State private var showScanner = false
    @State private var notice: Notice?

    private let sessionKey = "paxstore.auth.session"

    private enum NoticeStyle {
        case info
        case success
        case failure

        var color: Color {
            switch self {
            case .info: return .teal
            case .success: return .green
            case .failure: return .red
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
        let style: NoticeStyle
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.teal)
                        .frame(width: 52, height: 52)
                        .background(Color.teal.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session 備份")
                            .font(.headline)
                        Text("以 QR Code 在設備間移轉登入狀態")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 16) {
                    if let qrImage = qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 320)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel("Session 匯出二維碼")

                        Text("在另一部設備選擇「掃描二維碼」以導入")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 58, weight: .light))
                            .foregroundColor(.teal.opacity(0.75))
                            .frame(height: 150)
                            .accessibilityHidden(true)

                        Text("尚未生成二維碼")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack(spacing: 12) {
                    Button(action: generateQR) {
                        Label("生成二維碼", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)

                    Button {
                        notice = nil
                        showScanner = true
                    } label: {
                        Label("掃描二維碼", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.teal)
                }

                if let notice = notice {
                    Label(notice.text, systemImage: notice.style.symbol)
                        .font(.subheadline)
                        .foregroundColor(notice.style.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(notice.style.color.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityAddTraits(.updatesFrequently)
                }

                Label {
                    Text("二維碼包含敏感登入資料。只在可信任的設備間使用，請勿分享或公開展示。")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Session 二維碼")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView(
                onResult: { qrText in
                    showScanner = false
                    importSession(from: qrText)
                },
                onCancel: {
                    showScanner = false
                }
            )
            .ignoresSafeArea()
        }
    }

    private func generateQR() {
        qrImage = nil
        notice = nil

        guard let sessionData = KeychainHelper.load(forKey: sessionKey) else {
            notice = Notice(text: "沒有已保存的 Session", style: .failure)
            return
        }

        // 維持既有匯出格式：將 Keychain 中的 Session 原始 JSON 資料做 Base64 編碼。
        let base64 = sessionData.base64EncodedString()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(base64.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            notice = Notice(text: "無法生成二維碼，請稍後再試。", style: .failure)
            return
        }

        qrImage = UIImage(cgImage: cgImage)
        notice = Notice(text: "二維碼已生成。請妥善保管並避免讓他人掃描。", style: .success)
    }

    private func importSession(from qrText: String) {
        // QR payload 維持既有的 Base64 格式；只移除掃描器可能附帶的首尾空白。
        let base64 = qrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base64.isEmpty, base64.utf8.count <= 16_384,
              let data = Data(base64Encoded: base64) else {
            notice = Notice(text: "二維碼格式錯誤，未變更現有 Session。", style: .failure)
            return
        }

        // 與登入恢復流程使用相同的 Codable 型別驗證，避免將任意資料寫入 Session 項目。
        guard (try? JSONDecoder().decode(SideSign.AuthSession.self, from: data)) != nil else {
            notice = Notice(text: "二維碼不包含有效的 Session，未變更現有 Session。", style: .failure)
            return
        }

        if KeychainHelper.save(data, forKey: sessionKey) {
            notice = Notice(text: "Session 導入成功。", style: .success)
        } else {
            notice = Notice(text: "Session 寫入失敗。", style: .failure)
        }
    }
}

/// 二維碼掃描器
struct QRScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let viewController = ScannerViewController()
        viewController.onResult = onResult
        viewController.onCancel = onCancel
        return viewController
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// UIKit 相機掃描器；擷取工作使用獨立序列佇列，畫面更新與結果回呼留在主執行緒。
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.eili.eilistore.session-qr-capture")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    // 僅在 captureQueue 讀寫。
    private var isCancelled = false
    private var isConfigured = false
    // 以下狀態只在主執行緒讀寫。
    private var isClosing = false
    private var didHandleResult = false

    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let scanFrame = UIView()
    private let statusLabel = UILabel()
    private let settingsButton = UIButton(type: .system)

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        configureOverlay()
        checkCameraPermission()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
    }

    private func configureOverlay() {
        closeButton.setTitle("取消", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        closeButton.layer.cornerRadius = 20
        closeButton.addTarget(self, action: #selector(cancelScanning), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        titleLabel.text = "掃描 Session 二維碼"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        scanFrame.layer.borderColor = UIColor.systemTeal.cgColor
        scanFrame.layer.borderWidth = 3
        scanFrame.layer.cornerRadius = 24
        scanFrame.backgroundColor = .clear
        scanFrame.isUserInteractionEnabled = false
        scanFrame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanFrame)

        statusLabel.text = "正在檢查相機權限…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        statusLabel.layer.cornerRadius = 12
        statusLabel.layer.masksToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        settingsButton.setTitle("前往設定", for: .normal)
        settingsButton.setTitleColor(.white, for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        settingsButton.backgroundColor = .systemTeal
        settingsButton.layer.cornerRadius = 12
        settingsButton.isHidden = true
        settingsButton.addTarget(self, action: #selector(openAppSettings), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            closeButton.heightAnchor.constraint(equalToConstant: 42),

            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            scanFrame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            scanFrame.widthAnchor.constraint(equalToConstant: 268),
            scanFrame.heightAnchor.constraint(equalTo: scanFrame.widthAnchor),

            statusLabel.topAnchor.constraint(equalTo: scanFrame.bottomAnchor, constant: 22),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            settingsButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            settingsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            settingsButton.heightAnchor.constraint(equalToConstant: 46)
        ])
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartCapture()
        case .notDetermined:
            statusLabel.text = "請允許相機權限以掃描二維碼"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, !self.isClosing else { return }
                    if granted {
                        self.configureAndStartCapture()
                    } else {
                        self.showCameraUnavailable(
                            "相機權限未開啟。請允許 EiliStore 使用相機後再試。",
                            canOpenSettings: true
                        )
                    }
                }
            }
        case .denied:
            showCameraUnavailable(
                "相機權限已關閉。請到系統設定允許 EiliStore 使用相機。",
                canOpenSettings: true
            )
        case .restricted:
            showCameraUnavailable("此設備目前限制使用相機。", canOpenSettings: false)
        @unknown default:
            showCameraUnavailable("無法確認相機權限狀態。", canOpenSettings: false)
        }
    }

    private func configureAndStartCapture() {
        captureQueue.async { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            if self.isConfigured {
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                return
            }

            guard let device = AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async {
                    self.showScannerError("找不到可用的相機。")
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else {
                    DispatchQueue.main.async {
                        self.showScannerError("無法初始化相機輸入。")
                    }
                    return
                }
                self.captureSession.addInput(input)

                let output = AVCaptureMetadataOutput()
                guard self.captureSession.canAddOutput(output) else {
                    DispatchQueue.main.async {
                        self.showScannerError("無法初始化二維碼掃描器。")
                    }
                    return
                }
                self.captureSession.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    DispatchQueue.main.async {
                        self.showScannerError("此設備不支援 QR Code 掃描。")
                    }
                    return
                }
                output.metadataObjectTypes = [.qr]
                self.isConfigured = true

                DispatchQueue.main.async {
                    guard !self.isClosing else { return }
                    let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                    layer.videoGravity = .resizeAspectFill
                    self.view.layer.insertSublayer(layer, at: 0)
                    self.previewLayer = layer
                    self.view.setNeedsLayout()
                    self.statusLabel.text = "將 QR Code 對準框內，掃描會自動完成"

                    self.captureQueue.async {
                        guard !self.isCancelled else { return }
                        self.captureSession.startRunning()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.showScannerError("無法啟動相機：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showCameraUnavailable(_ message: String, canOpenSettings: Bool) {
        guard !isClosing else { return }
        scanFrame.isHidden = true
        statusLabel.text = message
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        settingsButton.isHidden = !canOpenSettings
    }

    private func showScannerError(_ message: String) {
        guard !isClosing else { return }
        scanFrame.isHidden = true
        statusLabel.text = message
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        settingsButton.isHidden = true
    }

    @objc private func applicationWillResignActive() {
        captureQueue.async { [weak self] in
            guard let self = self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard !isClosing,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        configureAndStartCapture()
    }

    private func stopCapture() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.isCancelled = true
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    @objc private func cancelScanning() {
        guard !isClosing else { return }
        isClosing = true
        stopCapture()
        onCancel?()
    }

    @objc private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:])
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didHandleResult,
              let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let text = code.stringValue,
              !text.isEmpty else { return }

        didHandleResult = true
        statusLabel.text = "已讀取二維碼，正在驗證 Session…"
        stopCapture()
        onResult?(text)
    }
}
