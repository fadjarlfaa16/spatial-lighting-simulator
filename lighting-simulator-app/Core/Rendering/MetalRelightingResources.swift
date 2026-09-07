import CoreGraphics
import Foundation
import Metal
import simd

enum MetalRelightingError: LocalizedError {
    case unavailable, allocation, shaderMissing, invalidBuffer, execution(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Metal tidak tersedia pada perangkat ini."
        case .allocation: "Tidak dapat mengalokasikan texture Metal."
        case .shaderMissing: "Shader relighting tidak ditemukan dalam app."
        case .invalidBuffer: "Buffer normal/mask tidak sesuai dimensinya."
        case .execution(let message): "Render Metal gagal: \(message)"
        }
    }
}

// Immutable textures and pipeline shared between the main-thread presenter and
// background export. Each submission owns its uniform bytes/command buffer;
// no mutable buffers are reused while GPU work is in flight.
final class MetalRelightingResources: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let width: Int
    let height: Int
    let photo: MTLTexture
    let normal: MTLTexture
    let mask: MTLTexture
    let hasMask: Bool

    init(
        originalImage: CGImage,
        normals: NormalBuffer,
        mask: ForegroundMaskBuffer? = nil
    ) throws {
        guard normals.width > 0, normals.height > 0,
              normals.normals.count == normals.width * normals.height else {
            throw MetalRelightingError.invalidBuffer
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw MetalRelightingError.unavailable }
        self.device = device
        self.queue = queue
        // The library belongs to the app target even when invoked by unit tests.
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalRelightingResources.self))
        guard let vertex = library.makeFunction(name: "relightVertex"),
              let fragment = library.makeFunction(name: "relightFragment") else {
            throw MetalRelightingError.shaderMissing
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let width = originalImage.width
        let height = originalImage.height
        self.width = width
        self.height = height
        let photo = try Self.makeTexture(device, width, height, .bgra8Unorm)
        self.photo = photo
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { throw MetalRelightingError.allocation }
            // Same top-row convention as preprocessing and the CPU reference.
            context.draw(originalImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            photo.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: storage.baseAddress!, bytesPerRow: width * 4)
        }
        normal = try Self.vectorTexture(device, normals.width, normals.height, normals.normals)
        hasMask = mask != nil
        if let mask {
            guard mask.width > 0, mask.height > 0,
                  mask.coverage.count == mask.width * mask.height else {
                throw MetalRelightingError.invalidBuffer
            }
            let texture = try Self.makeTexture(device, mask.width, mask.height, .r8Unorm)
            self.mask = texture
            mask.coverage.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, mask.width, mask.height),
                                mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: mask.width)
            }
        } else {
            self.mask = try Self.makeTexture(device, 1, 1, .r8Unorm)
            var full: UInt8 = 255
            self.mask.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                              withBytes: &full, bytesPerRow: 1)
        }
    }

    /// Copy-on-write mask replacement. Other GPU textures and the shader pipeline
    /// are shared; existing frames/exports can safely finish with the old mask.
    func replacingMask(_ coverage: ForegroundMaskBuffer) throws -> MetalRelightingResources {
        guard coverage.width > 0, coverage.height > 0,
              coverage.coverage.count == coverage.width * coverage.height else {
            throw MetalRelightingError.invalidBuffer
        }
        let texture = try Self.makeTexture(device, coverage.width, coverage.height, .r8Unorm)
        coverage.coverage.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, coverage.width, coverage.height),
                            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: coverage.width)
        }
        return MetalRelightingResources(copying: self, mask: texture)
    }

    private init(copying source: MetalRelightingResources, mask: MTLTexture) {
        device = source.device
        queue = source.queue
        pipeline = source.pipeline
        width = source.width
        height = source.height
        photo = source.photo
        normal = source.normal
        hasMask = true
        self.mask = mask
    }

    private static func makeTexture(
        _ device: MTLDevice, _ width: Int, _ height: Int, _ format: MTLPixelFormat,
        usage: MTLTextureUsage = .shaderRead
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalRelightingError.allocation
        }
        return texture
    }

    private static func vectorTexture(
        _ device: MTLDevice, _ width: Int, _ height: Int,
        _ vectors: [SIMD3<Float>]
    ) throws -> MTLTexture {
        let texture = try makeTexture(device, width, height, .rgba32Float)
        let values: [SIMD4<Float>] = vectors.map { v in
            let valid = v.x.isFinite && v.y.isFinite && v.z.isFinite
                && simd_length_squared(v) > 0.01
                && simd_length_squared(v).isFinite
            return valid ? SIMD4<Float>(v, 1) : .zero
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        return texture
    }

    /// No texture upload or CPU pixel loop here: only a small uniform snapshot.
    func encode(
        parameters: RelightingParameters,
        pass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRelightingError.allocation
        }
        var uniforms = GPUUniforms(parameters, aspect: Float(width) / Float(height),
                                   hasMask: hasMask)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        encoder.setFragmentTexture(photo, index: 0)
        encoder.setFragmentTexture(normal, index: 1)
        encoder.setFragmentTexture(mask, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func renderTarget() throws -> MTLTexture {
        try Self.makeTexture(device, width, height, .bgra8Unorm, usage: .renderTarget)
    }

    private func submit(parameters: RelightingParameters, target: MTLTexture) async throws -> Double {
        guard let command = queue.makeCommandBuffer() else { throw MetalRelightingError.allocation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try encode(parameters: parameters, pass: pass, commandBuffer: command)
        return try await withCheckedThrowingContinuation { continuation in
            command.addCompletedHandler { completed in
                if let error = completed.error {
                    continuation.resume(throwing: MetalRelightingError.execution(error.localizedDescription))
                } else {
                    continuation.resume(returning: max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000)
                }
            }
            command.commit()
        }
    }

    /// Only export reads GPU pixels back. Preview uses drawable presentation.
    func export(parameters: RelightingParameters) async throws -> CGImage {
        let target = try renderTarget()
        _ = try await submit(parameters: parameters, target: target)
        try Task.checkCancellation()
        return try autoreleasepool {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  ) else { throw ResultRenderingError.imageCreationFailed }
            return image
        }
    }

    /// Diagnostic only: fixed reusable full-resolution target, no readback. This
    /// measures shader throughput, NOT on-screen FPS or SwiftUI gesture latency.
    func benchmark(frameCount: Int = 120) async throws -> Double {
        let target = try renderTarget()
        var totalMS = 0.0
        for index in 0..<max(1, frameCount) {
            try Task.checkCancellation()
            var parameters = RelightingParameters.empty
            let sample = RelightLight(
                id: UUID(), normalizedPosition: SIMD2(0.5, 0.5),
                direction: SIMD3(0, 0, 1), distanceMeters: 1,
                radius: 0.5, falloffSoftness: 0.7,
                color: SIMD3(repeating: 1), intensity: 1
            )
            parameters.lights = Array(repeating: sample, count: 3)
            parameters.lights[0].normalizedPosition.x = Float(index % 100) / 100
            totalMS += try await submit(parameters: parameters, target: target)
        }
        return totalMS / Double(max(1, frameCount))
    }
}

private struct GPULight {
    var placement = SIMD4<Float>.zero
    var colorPower = SIMD4<Float>.zero
    var feather = SIMD4<Float>.zero

    init(_ light: RelightLight? = nil) {
        guard let light else { return }
        placement = SIMD4(
            finite(light.normalizedPosition.x, fallback: 0.5, range: 0...1),
            finite(light.normalizedPosition.y, fallback: 0.5, range: 0...1),
            finite(light.distanceMeters, fallback: 1, range: 0.05...50),
            finite(light.radius, fallback: 0.48, range: 0.04...2)
        )
        colorPower = SIMD4(
            finite(light.color.x, fallback: 1, range: 0...1),
            finite(light.color.y, fallback: 1, range: 0...1),
            finite(light.color.z, fallback: 1, range: 0...1),
            finite(light.intensity, fallback: 0, range: 0...100)
        )
        feather = SIMD4(
            finite(light.falloffSoftness, fallback: 0.75, range: 0.02...1),
            finite(light.direction.x, fallback: 0, range: -1...1),
            finite(light.direction.y, fallback: 0, range: -1...1),
            finite(light.direction.z, fallback: 1, range: -1...1)
        )
    }
}

private struct GPUUniforms {
    var material: SIMD4<Float>
    var scene: SIMD4<Float>
    var light0: GPULight
    var light1: GPULight
    var light2: GPULight

    init(_ p: RelightingParameters, aspect: Float, hasMask: Bool) {
        material = SIMD4(
            finite(p.ambientIntensity, fallback: 0, range: 0...100),
            finite(p.diffuseStrength, fallback: 0, range: 0...100),
            finite(p.specularStrength, fallback: 0, range: 0...100),
            finite(p.specularShininess, fallback: 64, range: 1...1024)
        )
        scene = SIMD4(aspect, Float(min(p.lights.count, 3)), hasMask ? 1 : 0, 0)
        light0 = GPULight(p.lights.first)
        light1 = GPULight(p.lights.count > 1 ? p.lights[1] : nil)
        light2 = GPULight(p.lights.count > 2 ? p.lights[2] : nil)
    }
}

private func finite(_ value: Float, fallback: Float, range: ClosedRange<Float>) -> Float {
    min(max(value.isFinite ? value : fallback, range.lowerBound), range.upperBound)
}
