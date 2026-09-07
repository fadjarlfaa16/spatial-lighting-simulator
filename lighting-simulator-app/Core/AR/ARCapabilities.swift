//
//  ARCapabilities.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import ARKit

struct ARCapabilities: Equatable, Sendable {
  let worldTracking: Bool

  static func detect() -> ARCapabilities {
    ARCapabilities(worldTracking: ARWorldTrackingConfiguration.isSupported)
  }
}

enum ARServiceError: LocalizedError, Equatable {
  case cameraPermissionDenied
  case worldTrackingUnavailable
  case noCurrentFrame
  case highResolutionCaptureFailed(String)
  case imageEncodingFailed
  case raycastFailed(String)

  var errorDescription: String? {
    switch self {
    case .cameraPermissionDenied:
      return "Camera access is denied. Enable Camera for this app in Settings."
    case .worldTrackingUnavailable:
      return "AR world tracking is unavailable on this device."
    case .noCurrentFrame:
      return "AR tracking has not produced a camera frame yet."
    case .highResolutionCaptureFailed(let reason):
      return "Foto resolusi tinggi gagal diambil: \(reason)"
    case .imageEncodingFailed:
      return "Frame kamera tidak dapat disimpan sebagai foto."
    case .raycastFailed(let context):
      return "No surface was found for \(context). Move the phone slowly and scan the area first."
    }
  }
}
