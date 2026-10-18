import SwiftUI
import UIKit

/// Avoid SwiftUI's fractional resampling of a one-pixel-per-module source image.
struct SessionQRCodeDisplay: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PixelAlignedQRCodeView {
        PixelAlignedQRCodeView()
    }

    func updateUIView(_ uiView: PixelAlignedQRCodeView, context: Context) {
        uiView.source = image.cgImage
    }
}

final class PixelAlignedQRCodeView: UIView {
    var source: CGImage? {
        didSet {
            renderedPixelSide = nil
            setNeedsLayout()
        }
    }

    private let imageView = UIImageView()
    private var renderedPixelSide: Int?
    private var renderedScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        isAccessibilityElement = false
        imageView.contentMode = .topLeft
        imageView.isAccessibilityElement = false
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let pixelSide = Int(floor(min(bounds.width, bounds.height) * scale))
        if renderedPixelSide != pixelSide || renderedScale != scale {
            renderedPixelSide = pixelSide
            renderedScale = scale
            if let source = source,
               let rendered = SessionQRCode.render(source, fittingPixelSide: pixelSide) {
                imageView.image = UIImage(cgImage: rendered, scale: scale, orientation: .up)
            } else {
                imageView.image = nil
            }
        }
        let size = imageView.image?.size ?? .zero
        imageView.frame = CGRect(
            x: floor((bounds.width - size.width) * scale / 2) / scale,
            y: floor((bounds.height - size.height) * scale / 2) / scale,
            width: size.width, height: size.height
        )
    }
}

struct ExpandedSessionQRCode: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Session 二維碼")
                    .font(.headline)
                Spacer()
                Button("關閉") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                SessionQRCodeDisplay(image: image)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Session 匯出二維碼")
            }
            .padding(8)

            Text("請用另一部可信任的設備掃描。請勿分享或公開展示。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical)
        .foregroundColor(.black)
        .background(Color.white.ignoresSafeArea())
    }
}
