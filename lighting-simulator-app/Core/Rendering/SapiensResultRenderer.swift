import CoreGraphics
import Foundation

nonisolated enum ResultRenderingError: LocalizedError {
    case invalidBuffer
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidBuffer: "Buffer visualisasi tidak valid."
        case .imageCreationFailed: "CGImage hasil tidak dapat dibuat."
        }
    }
}

nonisolated struct SapiensResultRenderer: Sendable {
    func makeNormalMap(from buffer: NormalBuffer) throws -> CGImage {
        guard buffer.width > 0, buffer.height > 0,
              buffer.normals.count == buffer.width * buffer.height else {
            throw ResultRenderingError.invalidBuffer
        }
        var rgba = [UInt8](repeating: 0, count: buffer.width * buffer.height * 4)
        for (index, normal) in buffer.normals.enumerated() {
            let base = index * 4
            rgba[base] = byte(normal.x * 0.5 + 0.5)
            rgba[base + 1] = byte(normal.y * 0.5 + 0.5)
            rgba[base + 2] = byte(normal.z * 0.5 + 0.5)
            rgba[base + 3] = 255
        }
        return try makeImage(bytes: rgba, width: buffer.width, height: buffer.height)
    }

    func makeMask(from buffer: ForegroundMaskBuffer) throws -> CGImage {
        guard buffer.width > 0, buffer.height > 0,
              buffer.coverage.count == buffer.width * buffer.height else {
            throw ResultRenderingError.invalidBuffer
        }
        var rgba = [UInt8](repeating: 0, count: buffer.width * buffer.height * 4)
        for (index, value) in buffer.coverage.enumerated() {
            let base = index * 4
            rgba[base] = value
            rgba[base + 1] = value
            rgba[base + 2] = value
            rgba[base + 3] = 255
        }
        return try makeImage(bytes: rgba, width: buffer.width, height: buffer.height)
    }

    private func byte(_ value: Float) -> UInt8 {
        UInt8((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded())
    }

    private func makeImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              ) else { throw ResultRenderingError.imageCreationFailed }
        return image
    }
}
