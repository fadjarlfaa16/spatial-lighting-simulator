//
//  ARSessionService.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

@preconcurrency import ARKit
import AVFoundation
import Combine
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated struct ARCapturedPhoto: @unchecked Sendable {
  let data: Data
  let cameraTransform: simd_float4x4
  let calibration: CameraCalibration
}

@MainActor
protocol ARSessionServiceProtocol: AnyObject {
  var session: ARSession { get }
  var capabilities: ARCapabilities { get }
  var currentFrame: ARFrame? { get }
  var cameraTransform: simd_float4x4? { get }
  var trackingDescription: String { get }
  var roomBoundary: RoomBoundary? { get }
  func start(resetTracking: Bool) async throws
  func captureHighResolutionPhoto() async throws -> ARCapturedPhoto
  func stopAndRelease()
  func raycastFromCameraCenter(alignment: ARRaycastQuery.TargetAlignment, context: String) throws
    -> SIMD3<Float>
  func raycastHitFromCameraCenter(alignment: ARRaycastQuery.TargetAlignment, context: String) throws
    -> WorldRaycastHit
}

@MainActor
final class ARSessionService: NSObject, ObservableObject, ARSessionServiceProtocol {
  let session: ARSession
  let capabilities: ARCapabilities

  @Published private(set) var currentFrame: ARFrame?
  @Published private(set) var cameraTransform: simd_float4x4?
  @Published private(set) var trackingDescription = "Not started"
  @Published private(set) var roomBoundary: RoomBoundary?
  @Published private(set) var interruptionMessage: String?
  @Published private(set) var isRunning = false

  override init() {
    session = ARSession()
    capabilities = .detect()
    super.init()
    session.delegate = self
  }

  func start(resetTracking: Bool = false) async throws {
    guard capabilities.worldTracking else { throw ARServiceError.worldTrackingUnavailable }
    guard await requestCameraAccess() else { throw ARServiceError.cameraPermissionDenied }

    let configuration = ARWorldTrackingConfiguration()
    configuration.worldAlignment = .gravity
    configuration.planeDetection = [.horizontal, .vertical]
    configuration.environmentTexturing = .none
    // Deliberately no sceneReconstruction, sceneDepth, or personSegmentationWithDepth.
    // This flow requires only world tracking and raycasts, so it works without LiDAR.
    if let qualityFormat = ARWorldTrackingConfiguration
      .recommendedVideoFormatForHighResolutionFrameCapturing
      ?? ARWorldTrackingConfiguration.supportedVideoFormats.max(by: {
      let lhsPixels = $0.imageResolution.width * $0.imageResolution.height
      let rhsPixels = $1.imageResolution.width * $1.imageResolution.height
      if lhsPixels == rhsPixels { return $0.framesPerSecond > $1.framesPerSecond }
      return lhsPixels < rhsPixels
    }) {
      configuration.videoFormat = qualityFormat
    }

    let options: ARSession.RunOptions =
      resetTracking
      ? [.resetTracking, .removeExistingAnchors]
      : []
    session.run(configuration, options: options)
    isRunning = true
    interruptionMessage = nil
    if resetTracking { roomBoundary = nil }
  }

  func captureHighResolutionPhoto() async throws -> ARCapturedPhoto {
    guard session.currentFrame != nil else { throw ARServiceError.noCurrentFrame }
    let capturedOrientation = currentImageOrientation()

    return try await withCheckedThrowingContinuation { continuation in
      session.captureHighResolutionFrame { frame, error in
        if let error {
          continuation.resume(throwing: ARServiceError.highResolutionCaptureFailed(
            error.localizedDescription
          ))
          return
        }
        guard let frame else {
          continuation.resume(throwing: ARServiceError.noCurrentFrame)
          return
        }

        do {
          let data = try Self.jpegData(
            from: frame.capturedImage,
            orientation: capturedOrientation
          )
          let intrinsics = frame.camera.intrinsics
          let resolution = frame.camera.imageResolution
          continuation.resume(returning: ARCapturedPhoto(
            data: data,
            cameraTransform: frame.camera.transform,
            calibration: CameraCalibration(
              fx: intrinsics.columns.0.x,
              fy: intrinsics.columns.1.y,
              cx: intrinsics.columns.2.x,
              cy: intrinsics.columns.2.y,
              sensorWidth: Float(resolution.width),
              sensorHeight: Float(resolution.height),
              imageOrientation: capturedOrientation
            )
          ))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func currentImageOrientation() -> CapturedImageOrientation {
    // UIDevice.orientation frequently reports faceUp/unknown at the shutter.
    // Interface orientation is stable for this landscape-only app and is the
    // coordinate space the user actually composed in.
    let interfaceOrientation = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.effectiveGeometry.interfaceOrientation }
      .first(where: { $0 != .unknown }) ?? .landscapeLeft
    return switch interfaceOrientation {
    // The rear-camera sensor buffer is native when the interface is landscape
    // right. ImageIO consumes this EXIF orientation exactly once downstream.
    case .landscapeRight: .up
    case .landscapeLeft: .down
    case .portraitUpsideDown: .left
    case .portrait: .right
    default: .up
    }
  }

  nonisolated private static func jpegData(
    from pixelBuffer: CVPixelBuffer,
    orientation: CapturedImageOrientation
  ) throws -> Data {
    try autoreleasepool {
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let image = context.createCGImage(ciImage, from: ciImage.extent) else {
        throw ARServiceError.imageEncodingFailed
      }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ) else { throw ARServiceError.imageEncodingFailed }
      let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation.exifRawValue,
        kCGImageDestinationLossyCompressionQuality: 0.96
      ]
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw ARServiceError.imageEncodingFailed
      }
      return data as Data
    }
  }

  func stopAndRelease() {
    session.pause()
    currentFrame = nil
    cameraTransform = nil
    roomBoundary = nil
    interruptionMessage = nil
    trackingDescription = "Stopped"
    isRunning = false
  }

  func raycastFromCameraCenter(
    alignment: ARRaycastQuery.TargetAlignment,
    context: String
  ) throws -> SIMD3<Float> {
    try raycastHitFromCameraCenter(alignment: alignment, context: context).position.simd
  }

  func raycastHitFromCameraCenter(
    alignment: ARRaycastQuery.TargetAlignment,
    context: String
  ) throws -> WorldRaycastHit {
    guard let transform = session.currentFrame?.camera.transform else {
      throw ARServiceError.noCurrentFrame
    }

    let origin = transform.translation
    let direction = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    let targets: [ARRaycastQuery.Target] = [
      .existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane,
    ]

    for target in targets {
      let query = ARRaycastQuery(
        origin: origin, direction: direction, allowing: target, alignment: alignment)
      if let result = session.raycast(query).first {
        let normalValue = SIMD3(
          result.worldTransform.columns.1.x,
          result.worldTransform.columns.1.y,
          result.worldTransform.columns.1.z
        )
        let normal =
          simd_length(normalValue) > 0.001 ? simd_normalize(normalValue) : SIMD3<Float>(0, 1, 0)
        return WorldRaycastHit(
          position: SpatialVector(result.worldTransform.translation),
          normal: SpatialVector(normal),
          isHorizontal: abs(simd_dot(normal, SIMD3<Float>(0, 1, 0))) > 0.85
        )
      }
    }
    throw ARServiceError.raycastFailed(context)
  }

  private func requestCameraAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func updateBoundary(using anchors: [ARAnchor]) {
    for anchor in anchors {
      let center: SIMD3<Float>
      let padding: Float
      if let plane = anchor as? ARPlaneAnchor {
        center = (plane.transform * SIMD4(plane.center.x, plane.center.y, plane.center.z, 1)).xyz
        padding = max(plane.planeExtent.width, plane.planeExtent.height) / 2
      } else {
        continue
      }

      if roomBoundary == nil {
        roomBoundary = .around(center, radius: max(padding, 0.5))
      } else {
        roomBoundary?.include(center, padding: max(padding, 0.25))
      }
    }
  }
}

extension ARSessionService: ARSessionDelegate {
  nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let transform = frame.camera.transform
    let description = Self.describe(frame.camera.trackingState)
    Task { @MainActor [weak self] in
      self?.currentFrame = frame
      self?.cameraTransform = transform
      self?.trackingDescription = description
    }
  }

  nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    Task { @MainActor [weak self] in self?.updateBoundary(using: anchors) }
  }

  nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    Task { @MainActor [weak self] in self?.updateBoundary(using: anchors) }
  }

  nonisolated func sessionWasInterrupted(_ session: ARSession) {
    Task { @MainActor [weak self] in
      self?.interruptionMessage =
        "AR session interrupted. Keep the device still while tracking resumes."
    }
  }

  nonisolated func sessionInterruptionEnded(_ session: ARSession) {
    Task { @MainActor [weak self] in
      self?.interruptionMessage = nil
    }
  }

  nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
    let message = error.localizedDescription
    Task { @MainActor [weak self] in
      self?.trackingDescription = "Unavailable"
      self?.interruptionMessage = message
    }
  }

  nonisolated private static func describe(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal:
      return "Normal"
    case .notAvailable:
      return "Unavailable"
    case .limited(let reason):
      switch reason {
      case .initializing: return "Limited · Initializing"
      case .excessiveMotion: return "Limited · Move more slowly"
      case .insufficientFeatures: return "Limited · Scan textured surfaces"
      case .relocalizing: return "Limited · Relocalizing"
      @unknown default: return "Limited"
      }
    }
  }
}

extension SIMD4 where Scalar == Float {
  fileprivate var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
