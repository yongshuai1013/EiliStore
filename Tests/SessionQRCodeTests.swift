import Foundation
import CoreGraphics
import CoreImage.CIFilterBuiltins
import Vision

/// Uses synthetic, non-authenticating data only. Never print payloads or save QR images.
@main
struct SessionQRCodeTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        let legacyJSON = Data("{\n  \"fixture\": \"synthetic-only\"\n}\n".utf8)
        require(SessionQRCode.payload(for: legacyJSON) == Data(legacyJSON.base64EncodedString().utf8),
                "Legacy payload bytes changed")
        require(Data(base64Encoded: String(decoding: SessionQRCode.payload(for: legacyJSON), as: UTF8.self)) == legacyJSON,
                "Legacy JSON bytes were not preserved")

        // Different synthetic JSON sizes exercise increasing module counts.
        for length in [32, 256, 768, 1400] {
            var value: UInt32 = 42
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
            let token = (0..<length).map { _ -> UInt8 in
                value = value &* 1664525 &+ 1013904223
                return alphabet[Int(value % UInt32(alphabet.count))]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "account": "synthetic@example.invalid",
                "token": "SYNTHETIC-NOT-VALID-" + String(decoding: token, as: UTF8.self)
            ], options: [.sortedKeys])
            guard let source = SessionQRCode.makeImage(for: data) else {
                fatalError("Synthetic fixture should fit into one QR")
            }
            let legacyFilter = CIFilter.qrCodeGenerator()
            legacyFilter.message = SessionQRCode.payload(for: data)
            legacyFilter.correctionLevel = "M"
            guard let legacyOutput = legacyFilter.outputImage else {
                fatalError("Legacy comparison fixture should fit into one QR")
            }
            require(CGFloat(source.width) <= legacyOutput.extent.width,
                    "Screen QR must not be denser than the legacy M-level QR")
            if length >= 768 {
                require(CGFloat(source.width) < legacyOutput.extent.width,
                        "Large fixture should use fewer modules than legacy QR")
            }
            let moduleSide = source.width + SessionQRCode.quietZoneModules * 2
            require(SessionQRCode.render(source, fittingPixelSide: moduleSide - 1) == nil,
                    "Renderer must not shrink modules below one pixel")
            // 1x/2x/3x displays, narrow phones, expanded views, fractional layouts and rotation.
            for target in [237, 280, 320, 351, 390, 640, 750, 1170, 1536] {
                guard let rendered = SessionQRCode.render(source, fittingPixelSide: target) else {
                    fatalError("Synthetic QR rendering failed")
                }
                let factor = target / moduleSide
                let side = moduleSide * factor
                require(rendered.width == side && rendered.height == side && side <= target,
                        "Output must fit using whole pixel modules")
                require(rendered.alphaInfo == .none, "QR background must be opaque")
                let pixels = [UInt8](rendered.dataProvider!.data! as Data)
                let stride = rendered.bytesPerRow
                let inset = SessionQRCode.quietZoneModules * factor
                for y in 0..<side {
                    for x in 0..<side {
                        let pixel = pixels[y * stride + x]
                        require(pixel == 0 || pixel == 255, "Resampling introduced gray pixels")
                        if x < inset || y < inset || x >= side - inset || y >= side - inset {
                            require(pixel == 255, "Quiet zone must remain white")
                        }
                        require(pixel == pixels[(y / factor * factor) * stride + x / factor * factor],
                                "A module was split or resampled")
                    }
                }
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(cgImage: rendered, options: [:]).perform([request])
                let decoded = request.results?.first?.payloadStringValue
                require(decoded == String(decoding: SessionQRCode.payload(for: data), as: UTF8.self),
                        "Decoded QR must match the legacy Base64 payload exactly")
                require(decoded.flatMap { Data(base64Encoded: $0) } == data,
                        "Decoded session bytes must be identical")
            }
        }
        require(SessionQRCode.makeImage(for: Data(repeating: 65, count: 10_000)) == nil,
                "Over-capacity payload should fail without truncation")
        print("Session QR tests passed (synthetic fixtures only).")
    }
}
