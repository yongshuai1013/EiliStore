import Foundation
import CoreGraphics
import CoreImage.CIFilterBuiltins

/// Local-only rendering. Never persist or log the payload or rendered image.
enum SessionQRCode {
    // Four full white modules on every side, independent of any border emitted by Core Image.
    static let quietZoneModules = 4

    static func payload(for sessionData: Data) -> Data {
        // Keep the legacy raw JSON -> Base64 -> UTF-8 wire format byte-for-byte.
        Data(sessionData.base64EncodedString().utf8)
    }

    static func makeImage(for sessionData: Data) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload(for: sessionData)
        // Clean screen-to-camera transfer: L uses fewer modules for the same payload.
        // Trade-off: less tolerance of occlusion/damage than M; keep the full code visible.
        // Error correction is encoded in the symbol, so existing importers remain compatible.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Every source module occupies an integer number of physical display pixels.
    /// The returned opaque square includes its quiet zone; callers must not rescale it.
    static func render(_ image: CGImage, fittingPixelSide: Int) -> CGImage? {
        guard image.width == image.height, image.width > 0 else { return nil }
        let moduleSide = image.width + quietZoneModules * 2
        let pixelsPerModule = fittingPixelSide / moduleSide
        guard pixelsPerModule >= 1 else { return nil }
        let side = moduleSide * pixelsPerModule
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        let inset = quietZoneModules * pixelsPerModule
        context.draw(image, in: CGRect(
            x: inset, y: inset,
            width: image.width * pixelsPerModule, height: image.height * pixelsPerModule
        ))
        return context.makeImage()
    }
}
