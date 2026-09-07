//
//  PhotoCompressor.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct CompressedPhoto: Sendable {
    let image: CGImage
    let jpegData: Data
}

nonisolated protocol PhotoCompressing: Sendable {
    func compress(_ data: Data, maximumDimension: Int, quality: CGFloat) throws -> CompressedPhoto
}

nonisolated struct PhotoCompressor: PhotoCompressing {
    func compress(
        _ data: Data,
        maximumDimension: Int = 2_048,
        quality: CGFloat = 0.88
    ) throws -> CompressedPhoto {
        let image = try ImageOrientationNormalizer(
            maximumPixelDimension: maximumDimension
        ).normalize(data: data)
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ImageOrientationError.renderFailed }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1)
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageOrientationError.renderFailed
        }
        return CompressedPhoto(image: image, jpegData: mutable as Data)
    }
}
