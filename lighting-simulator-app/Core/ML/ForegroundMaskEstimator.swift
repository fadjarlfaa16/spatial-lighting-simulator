import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

nonisolated enum ForegroundMaskError: LocalizedError {
    case noSubjects, invalidBuffer, unsupportedFormat(OSType)

    var errorDescription: String? {
        switch self {
        case .noSubjects: "Vision tidak menemukan foreground. Gunakan mode manusia jika fotonya portrait."
        case .invalidBuffer: "Mask foreground memiliki buffer yang tidak valid."
        case .unsupportedFormat(let format): "Format mask Vision tidak didukung: \(format)."
        }
    }
}

/// Class-agnostic subject lifting, NOT nearest-depth detection. Called on the
/// analyzer's worker actor once per photo, never by a slider or Metal draw.
nonisolated struct ForegroundMaskEstimator: Sendable {
    func estimateMask(from uprightImage: CGImage) throws -> ForegroundMaskBuffer {
        try autoreleasepool {
            try Task.checkCancellation()
            let handler = VNImageRequestHandler(cgImage: uprightImage, orientation: .up)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            try Task.checkCancellation()
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { throw ForegroundMaskError.noSubjects }
            // High-resolution SOFT alpha of every instance, not integer labels.
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler
            )
            guard CVPixelBufferGetWidth(buffer) == uprightImage.width,
                  CVPixelBufferGetHeight(buffer) == uprightImage.height else {
                throw ForegroundMaskError.invalidBuffer
            }
            return try decodeMask(buffer)
        }
    }

    /// Row-stride-aware conversion; fractional alpha survives without threshold
    /// or broad blur, preserving fine boundaries rather than creating halos.
    func decodeMask(_ buffer: CVPixelBuffer) throws -> ForegroundMaskBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard width > 0, height > 0, !CVPixelBufferIsPlanar(buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ForegroundMaskError.invalidBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ForegroundMaskError.invalidBuffer
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float
                || format == kCVPixelFormatType_OneComponent8 else {
            throw ForegroundMaskError.unsupportedFormat(format)
        }
        let bytesPerValue = format == kCVPixelFormatType_OneComponent32Float ? 4 : 1
        guard stride >= width * bytesPerValue else { throw ForegroundMaskError.invalidBuffer }
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            if y.isMultiple(of: 64) { try Task.checkCancellation() }
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                if bytesPerValue == 4 {
                    let value = row.assumingMemoryBound(to: Float.self)[x]
                    coverage[y * width + x] = value.isFinite
                        ? UInt8((min(max(value, 0), 1) * 255).rounded()) : 0
                } else {
                    coverage[y * width + x] = row.assumingMemoryBound(to: UInt8.self)[x]
                }
            }
        }
            return ForegroundMaskBuffer(width: width, height: height, coverage: coverage)
    }
}
