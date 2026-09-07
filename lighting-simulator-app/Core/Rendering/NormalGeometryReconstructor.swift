import Foundation
import Metal
import simd

// MARK: - DepthFieldBuffer

/// Compact in-memory representation of the reconstructed relative depth field.
/// Values are in metres relative to the AR-measured subject anchor depth.
nonisolated struct DepthFieldBuffer: Sendable {
    let width: Int
    let height: Int
    /// Relative depth in metres per pixel; positive = closer to camera.
    let depths: [Float]
}

// MARK: - NormalGeometryReconstructor

/// Derives a conservative surface relief (height field) from the Sapiens normal
/// map without requiring a separate depth/pointmap model.
///
/// The integration runs once per photograph and the result is uploaded to a
/// reusable Metal texture. No reconstruction happens when sliders move.
///
/// **Coordinate convention:** The normal map uses the Sapiens camera convention
/// where +Z points toward the camera. Gradients are:
///   dz/dx = -Nx / max(Nz, epsilon)
///   dz/dy = -Ny / max(Nz, epsilon)
///
/// Integration is averaged from two passes (left->right columns, top->bottom
/// rows) to reduce directional bias. Edge-aware weights prevent relief from
/// bleeding across RGB/normal discontinuities or across the foreground mask
/// boundary.
nonisolated enum NormalGeometryReconstructor {

    /// Conservative clamp on per-pixel relief, in metres.
    /// At 2-4 m scene depth a +/-0.25 m surface relief is physically plausible
    /// for a human subject and most studio scenes.
    static let maxReliefMetres: Float = 0.25

    /// Pixels whose mask value is below this threshold are treated as
    /// background and integrated independently.
    static let foregroundThreshold: UInt8 = 32

    // MARK: - Public API

    /// Reconstruct a relative depth field from a normal buffer and optional
    /// foreground mask. This function is CPU-bound and may take 50-200 ms for
    /// a typical inference resolution (512-1024 px).
    ///
    /// - Parameters:
    ///   - normals:   Unit surface normals from Sapiens inference.
    ///   - mask:      Soft foreground mask (0-255); nil means full-frame.
    ///   - photoRGB:  Optional RGB image (same layout as normals) for edge
    ///                weights. When nil, only normal discontinuities are used.
    /// - Returns: Relative depth field in metres; positive = closer to camera.
    static func reconstruct(
        from normals: NormalBuffer,
        mask: ForegroundMaskBuffer? = nil,
        photoRGB: [SIMD3<Float>]? = nil
    ) -> DepthFieldBuffer {
        let width = normals.width
        let height = normals.height
        let count = width * height
        guard count > 0 else {
            return DepthFieldBuffer(width: width, height: height, depths: [])
        }

        let (gx, gy) = computeGradients(normals: normals.normals, width: width, height: height)
        let weights = computeEdgeWeights(
            normals: normals.normals,
            mask: mask,
            photoRGB: photoRGB,
            width: width,
            height: height
        )
        let passH = integrateHorizontal(gx: gx, gy: gy, weights: weights, width: width, height: height)
        let passV = integrateVertical(gx: gx, gy: gy, weights: weights, width: width, height: height)

        var depths = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let avg = (passH[i] + passV[i]) * 0.5
            depths[i] = min(max(avg, -maxReliefMetres), maxReliefMetres)
        }
        centre(depths: &depths, mask: mask, width: width, height: height)
        return DepthFieldBuffer(width: width, height: height, depths: depths)
    }

    /// Upload a DepthFieldBuffer to a Metal device, returning a reusable
    /// read-only texture in .r32Float format.
    static func makeTexture(_ buffer: DepthFieldBuffer, device: MTLDevice) throws -> MTLTexture {
        guard buffer.width > 0, buffer.height > 0,
              buffer.depths.count == buffer.width * buffer.height else {
            throw NormalGeometryError.invalidDimensions
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: buffer.width,
            height: buffer.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NormalGeometryError.allocationFailed
        }
        buffer.depths.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, buffer.width, buffer.height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: buffer.width * MemoryLayout<Float>.stride
            )
        }
        return texture
    }

    // MARK: - Gradient Computation

    private static func computeGradients(
        normals: [SIMD3<Float>],
        width: Int,
        height: Int
    ) -> (gx: [Float], gy: [Float]) {
        let count = width * height
        var gx = [Float](repeating: 0, count: count)
        var gy = [Float](repeating: 0, count: count)
        let eps: Float = 0.02
        for row in 0..<height {
            for col in 0..<width {
                let idx = row * width + col
                let n = normals[idx]
                guard n.z > eps else { continue }
                // Clamp extreme gradients to prevent integration explosion
                gx[idx] = min(max(-n.x / n.z, -4), 4)
                gy[idx] = min(max(-n.y / n.z, -4), 4)
            }
        }
        return (gx, gy)
    }

    // MARK: - Edge-Aware Weights

    private static func computeEdgeWeights(
        normals: [SIMD3<Float>],
        mask: ForegroundMaskBuffer?,
        photoRGB: [SIMD3<Float>]?,
        width: Int,
        height: Int
    ) -> [Float] {
        let count = width * height
        var weights = [Float](repeating: 1, count: count)
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let idx  = row * width + col
                let idx1 = idx + 1
                let nDot = simd_dot(normals[idx], normals[idx1])
                let normalWeight = max(nDot, 0)
                var maskWeight: Float = 1
                if let mask {
                    let m0 = Float(mask.coverage[idx])  / 255
                    let m1 = Float(mask.coverage[idx1]) / 255
                    maskWeight = 1 - abs(m0 - m1)
                }
                var rgbWeight: Float = 1
                if let rgb = photoRGB {
                    let diff = simd_length(rgb[idx] - rgb[idx1])
                    rgbWeight = max(1 - diff * 4, 0)
                }
                weights[idx] = normalWeight * maskWeight * rgbWeight
            }
        }
        return weights
    }

    // MARK: - Integration Passes

    private static func integrateHorizontal(
        gx: [Float], gy: [Float],
        weights: [Float],
        width: Int, height: Int
    ) -> [Float] {
        var field = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            var acc: Float = 0
            for col in 1..<width {
                let idx = row * width + col
                let prev = idx - 1
                acc += gx[idx] * weights[prev]
                field[idx] = acc
            }
        }
        for col in 0..<width {
            var acc: Float = field[col]
            for row in 1..<height {
                let idx  = row * width + col
                let prev = idx - width
                let w = weights[max(prev, 0)]
                acc += gy[idx] * w
                field[idx] = field[idx] * 0.5 + acc * 0.5
            }
        }
        return field
    }

    private static func integrateVertical(
        gx: [Float], gy: [Float],
        weights: [Float],
        width: Int, height: Int
    ) -> [Float] {
        var field = [Float](repeating: 0, count: width * height)
        for col in 0..<width {
            var acc: Float = 0
            for row in 1..<height {
                let idx  = row * width + col
                let prev = idx - width
                acc += gy[idx] * weights[prev]
                field[idx] = acc
            }
        }
        for row in 0..<height {
            var acc: Float = field[row * width]
            for col in 1..<width {
                let idx  = row * width + col
                let prev = idx - 1
                let w = weights[prev]
                acc += gx[idx] * w
                field[idx] = field[idx] * 0.5 + acc * 0.5
            }
        }
        return field
    }

    // MARK: - Zero-Mean Centring

    private static func centre(
        depths: inout [Float],
        mask: ForegroundMaskBuffer?,
        width: Int,
        height: Int
    ) {
        let count = width * height
        guard count > 0 else { return }
        if let mask {
            var fgSum: Float = 0; var fgN = 0
            var bgSum: Float = 0; var bgN = 0
            for i in 0..<count {
                if mask.coverage[i] >= foregroundThreshold {
                    fgSum += depths[i]; fgN += 1
                } else {
                    bgSum += depths[i]; bgN += 1
                }
            }
            if fgN > 0 {
                let m = fgSum / Float(fgN)
                for i in 0..<count where mask.coverage[i] >= foregroundThreshold { depths[i] -= m }
            }
            if bgN > 0 {
                let m = bgSum / Float(bgN)
                for i in 0..<count where mask.coverage[i] < foregroundThreshold { depths[i] -= m }
            }
        } else {
            let mean = depths.reduce(0, +) / Float(count)
            for i in 0..<count { depths[i] -= mean }
        }
    }
}

// MARK: - Error

nonisolated enum NormalGeometryError: LocalizedError {
    case invalidDimensions
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "Depth field dimensions tidak valid."
        case .allocationFailed:  "Tidak dapat membuat Metal texture untuk depth field."
        }
    }
}
