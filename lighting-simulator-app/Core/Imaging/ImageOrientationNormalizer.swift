//
//  ImageOrientationNormalizer.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//



import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ImageOrientationError: LocalizedError {
    case undecodableImage
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .undecodableImage: "File tidak dapat dibaca sebagai gambar."
        case .renderFailed: "Orientasi gambar tidak dapat dinormalisasi."
        }
    }
}

nonisolated struct ImageOrientationNormalizer {
    /// The model sees at most 1024 pixels on its long axis. Retaining a 48 MP
    /// camera/library decode during three large Core ML passes only increases
    /// peak memory, so keep a high-quality display/render copy capped at 2048.
    let maximumPixelDimension: Int

    init(maximumPixelDimension: Int = 2_048) {
        self.maximumPixelDimension = max(64, maximumPixelDimension)
    }

    func normalize(data: Data) throws -> CGImage {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw ImageOrientationError.undecodableImage
        }

        // ImageIO performs orientation and downsampling during decode. This avoids
        // ever materializing the full-resolution source before resizing it.
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let output = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ) else {
            throw ImageOrientationError.renderFailed
        }
        return output
    }
}
