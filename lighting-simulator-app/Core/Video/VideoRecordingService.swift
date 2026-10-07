import AVFoundation
import Combine
import SwiftUI
import UIKit

enum VideoRecordingError: LocalizedError {
  case cameraUnavailable
  case cameraPermissionDenied
  case cannotAddInput
  case cannotAddOutput
  case notRecording

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable: "A rear camera is not available on this device."
    case .cameraPermissionDenied: "Camera access is required to record video."
    case .cannotAddInput: "The camera input could not be configured."
    case .cannotAddOutput: "The 720p video output could not be configured."
    case .notRecording: "No video recording is currently active."
    }
  }
}

/// Keeps preview and file-output orientation on the same convention. Unlike
/// the AR preview, an AVCaptureVideoPreviewLayer receives the camera buffer in
/// sensor space and therefore still needs a quarter-turn in landscape.
enum LandscapeVideoOrientation {
  static func rotationAngle(
    for orientation: UIInterfaceOrientation,
    cameraPosition: AVCaptureDevice.Position
  ) -> CGFloat {
    // Front and rear sensors have different native landscape bases. Mirroring
    // remains independent and is applied on the capture connection below.
    if cameraPosition == .front {
      return switch orientation {
      case .landscapeLeft: 270
      case .landscapeRight: 90
      case .portrait: 0
      case .portraitUpsideDown: 180
      default: 270
      }
    } else {
      return switch orientation {
      case .landscapeLeft: 180
      case .landscapeRight: 0
      case .portrait: 90
      case .portraitUpsideDown: 270
      default: 180
      }
    }
  }

  static var currentInterfaceOrientation: UIInterfaceOrientation {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: {
      $0.activationState == .foregroundActive
        && $0.effectiveGeometry.interfaceOrientation != .unknown
    })?.effectiveGeometry.interfaceOrientation
      ?? scenes.map(\.effectiveGeometry.interfaceOrientation)
        .first(where: { $0 != .unknown })
      ?? .landscapeLeft
  }
}

/// A normal camera recorder. AR is deliberately not revived here: the approved
/// still's SpatialPlanSnapshot is the single lighting reference for the video.
@MainActor
final class VideoRecordingService: NSObject, ObservableObject {
  let session = AVCaptureSession()
  private let movieOutput = AVCaptureMovieFileOutput()
  private var recordingContinuation: CheckedContinuation<URL, Error>?
  private(set) var isConfigured = false
  @Published private(set) var isRecording = false

  @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back

  func start() async throws {
    guard await requestCameraAccess() else { throw VideoRecordingError.cameraPermissionDenied }
    guard !isConfigured else {
      if !session.isRunning {
        Task.detached { [session = self.session] in session.startRunning() }
      }
      return
    }
    guard let device = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: cameraPosition
    ) else { throw VideoRecordingError.cameraUnavailable }

    session.beginConfiguration()
    do {
      session.sessionPreset = .hd1280x720
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else { throw VideoRecordingError.cannotAddInput }
      session.addInput(input)
      guard session.canAddOutput(movieOutput) else { throw VideoRecordingError.cannotAddOutput }
      session.addOutput(movieOutput)
      configureThirtyFramesPerSecond(device)
      session.commitConfiguration()
    } catch {
      session.commitConfiguration()
      throw error
    }
    isConfigured = true
    Task.detached { [session = self.session] in session.startRunning() }
  }

  func beginRecording() throws {
    guard isConfigured, !movieOutput.isRecording else { return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lighting-source-\(UUID().uuidString).mov"
    )
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    let angle = currentVideoRotationAngle()
    if let connection = movieOutput.connection(with: .video) {
      guard connection.isVideoRotationAngleSupported(angle) else {
        throw VideoRecordingError.cannotAddOutput
      }
      connection.videoRotationAngle = angle
      if connection.isVideoMirroringSupported {
        connection.isVideoMirrored = (cameraPosition == .front)
      }
    }
    movieOutput.startRecording(to: url, recordingDelegate: self)
    isRecording = true
  }

  func finishRecording() async throws -> URL {
    guard movieOutput.isRecording else { throw VideoRecordingError.notRecording }
    return try await withCheckedThrowingContinuation { continuation in
      recordingContinuation = continuation
      movieOutput.stopRecording()
    }
  }

  func stopAndRelease() async {
    if movieOutput.isRecording { movieOutput.stopRecording() }
    if session.isRunning {
      await Task.detached { [session] in session.stopRunning() }.value
    }
    isRecording = false
  }

  func toggleCamera() throws {
    guard !isRecording else { return }
    let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
    guard let newDevice = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: newPosition
    ) else { throw VideoRecordingError.cameraUnavailable }

    session.beginConfiguration()
    if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
      session.removeInput(currentInput)
    }

    do {
      let newInput = try AVCaptureDeviceInput(device: newDevice)
      guard session.canAddInput(newInput) else { throw VideoRecordingError.cannotAddInput }
      session.addInput(newInput)
      configureThirtyFramesPerSecond(newDevice)
      session.commitConfiguration()
      cameraPosition = newPosition
    } catch {
      session.commitConfiguration()
      throw error
    }
  }

  private func configureThirtyFramesPerSecond(_ device: AVCaptureDevice) {
    guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
      $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
    }) else { return }
    do {
      try device.lockForConfiguration()
      let duration = CMTime(value: 1, timescale: 30)
      device.activeVideoMinFrameDuration = duration
      device.activeVideoMaxFrameDuration = duration
      device.unlockForConfiguration()
    } catch {
      // The session still records at the device's closest supported rate.
    }
  }

  private func currentVideoRotationAngle() -> CGFloat {
    LandscapeVideoOrientation.rotationAngle(
      for: LandscapeVideoOrientation.currentInterfaceOrientation,
      cameraPosition: cameraPosition
    )
  }

  private func requestCameraAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
    case .denied, .restricted: false
    @unknown default: false
    }
  }
}

extension VideoRecordingService: AVCaptureFileOutputRecordingDelegate {
  nonisolated func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      isRecording = false
      let continuation = recordingContinuation
      recordingContinuation = nil
      if let error {
        continuation?.resume(throwing: error)
      } else {
        continuation?.resume(returning: outputFileURL)
      }
    }
  }
}

struct VideoCapturePreview: UIViewRepresentable {
  let session: AVCaptureSession
  let cameraPosition: AVCaptureDevice.Position

  func makeUIView(context: Context) -> VideoPreviewHostView {
    let view = VideoPreviewHostView()
    view.previewLayer.session = session
    return view
  }

  func updateUIView(_ view: VideoPreviewHostView, context: Context) {
    if view.previewLayer.session !== session { view.previewLayer.session = session }
    if let connection = view.previewLayer.connection {
      let angle = LandscapeVideoOrientation.rotationAngle(
        for: LandscapeVideoOrientation.currentInterfaceOrientation,
        cameraPosition: cameraPosition
      )
      if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
      }
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = cameraPosition == .front
      }
    }
  }
}

final class VideoPreviewHostView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

  var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    previewLayer.videoGravity = .resizeAspectFill
  }

  required init?(coder: NSCoder) { nil }
}
