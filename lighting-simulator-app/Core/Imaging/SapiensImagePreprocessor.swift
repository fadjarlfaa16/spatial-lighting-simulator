//
//  SapiensImagePreprocessor.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import CoreGraphics
import CoreML
import Foundation

nonisolated enum SapiensPreprocessingError: LocalizedError {
    case contextCreationFailed
    case tensorAllocationFailed(String)

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            "Tidak dapat membuat bitmap context untuk preprocessing."
        case let .tensorAllocationFailed(message):
            "Tidak dapat membuat tensor input Sapiens: \(message)"
        }
    }
}

nonisolated struct SapiensModelInput {
    static let width = 768
    static let height = 1024
    static let mean: SIMD3<Float> = .init(123.675, 116.28, 103.53)
    static let standardDeviation: SIMD3<Float> = .init(58.395, 57.12, 57.375)

    let tensor: MLMultiArray
    let transform: ImageLetterboxTransform
}

/// Reproduces Sapiens2 test preprocessing:
/// RGB orientation-normalized image -> aspect-fit 1024x768 -> centered zero padding
/// -> (RGB_0_255 - ImageNet mean) / ImageNet standard deviation -> NCHW Float32.
nonisolated struct SapiensImagePreprocessor {
    func prepare(_ image: CGImage) throws -> SapiensModelInput {
        let targetWidth = SapiensModelInput.width
        let targetHeight = SapiensModelInput.height
        let scale = min(
            CGFloat(targetWidth) / CGFloat(image.width),
            CGFloat(targetHeight) / CGFloat(image.height)
        )

        // Python uses int(original * scale), i.e. truncation rather than rounding.
        let contentWidth = max(1, Int(CGFloat(image.width) * scale))
        let contentHeight = max(1, Int(CGFloat(image.height) * scale))
        let padWidth = targetWidth - contentWidth
        let padHeight = targetHeight - contentHeight
        let left = padWidth / 2
        let right = padWidth - left
        let top = padHeight / 2
        let bottom = padHeight - top

        let bytesPerRow = targetWidth * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * targetHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // byteOrder32Little + premultipliedFirst (BGRA) is the native GPU format on all
        // Apple platforms (ARM and Intel are both little-endian). This is the only
        // alpha+32bpp layout that CoreGraphics accepts reliably across all devices.
        // The previous premultipliedLast + byteOrder32Big was invalid and returned nil.
        guard let context = CGContext(
            data: &rgba,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw SapiensPreprocessingError.contextCreationFailed
        }

        context.interpolationQuality = .medium
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        // CGContext uses a bottom-left coordinate origin. To place the content at
        // visual-top (with `top` rows of padding above it), we must invert the Y:
        //   cgY = totalHeight - topPadding - contentHeight
        // Using `y: top` directly would draw the image near the bottom, leaving the
        // wrong padding and sending a vertically-flipped tensor to the model.
        let cgY = targetHeight - top - contentHeight
        context.draw(
            image,
            in: CGRect(x: left, y: cgY, width: contentWidth, height: contentHeight)
        )

        let tensor: MLMultiArray
        do {
            tensor = try MLMultiArray(
                shape: [1, 3, NSNumber(value: targetHeight), NSNumber(value: targetWidth)],
                dataType: .float32
            )
        } catch {
            throw SapiensPreprocessingError.tensorAllocationFailed(error.localizedDescription)
        }

        let pointer = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
        let planeSize = targetWidth * targetHeight
        let mean = SapiensModelInput.mean
        let std = SapiensModelInput.standardDeviation

        // BGRA byte layout (byteOrder32Host + premultipliedFirst on little-endian Apple HW):
        //   pixel[0] = B,  pixel[1] = G,  pixel[2] = R,  pixel[3] = A
        // The Sapiens model expects RGB channels, so we read R←[+2], G←[+1], B←[+0].
        for y in 0..<targetHeight {
            let row = y * bytesPerRow
            let tensorRow = y * targetWidth
            for x in 0..<targetWidth {
                let pixel = row + x * 4
                let index = tensorRow + x
                pointer[index] = (Float(rgba[pixel + 2]) - mean.x) / std.x          // R
                pointer[planeSize + index] = (Float(rgba[pixel + 1]) - mean.y) / std.y   // G
                pointer[2 * planeSize + index] = (Float(rgba[pixel]) - mean.z) / std.z  // B
            }
        }

        return SapiensModelInput(
            tensor: tensor,
            transform: ImageLetterboxTransform(
                sourceWidth: image.width,
                sourceHeight: image.height,
                modelWidth: targetWidth,
                modelHeight: targetHeight,
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                paddingLeft: left,
                paddingRight: right,
                paddingTop: top,
                paddingBottom: bottom,
                scale: Float(scale)
            )
        )
    }
}
