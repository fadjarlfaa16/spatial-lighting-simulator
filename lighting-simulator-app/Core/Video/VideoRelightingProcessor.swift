@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct VideoRelightingProgress: Sendable, Equatable {
  let processedFrames: Int
  let estimatedFrameCount: Int

  var fraction: Double {
    guard estimatedFrameCount > 0 else { return 0 }
    return min(max(Double(processedFrames) / Double(estimatedFrameCount), 0), 1)
  }
}

enum VideoRelightingError: LocalizedError {
  case videoTrackMissing
  case readerSetupFailed
  case writerSetupFailed
  case frameConversionFailed
  case appendFailed
  case processingFailed(String)

  var errorDescription: String? {
    switch self {
    case .videoTrackMissing: "The recorded file does not contain a video track."
    case .readerSetupFailed: "The recorded video could not be opened for processing."
    case .writerSetupFailed: "The relit video could not be prepared for export."
    case .frameConversionFailed: "A video frame could not be converted for relighting."
    case .appendFailed: "A relit frame could not be added to the export movie."
    case .processingFailed(let message): "Video relighting failed: \(message)"
    }
  }
}

@MainActor
protocol VideoRelightingProcessing: Sendable {
  func process(
    inputURL: URL,
    parameters: RelightingParameters,
    progress: @escaping (VideoRelightingProgress) async -> Void
  ) async throws -> URL
}

/// Offline, frame-by-frame relighting. The approved photo's lighting parameters
/// are intentionally reused unchanged; the capture camera remains a normal
/// 720p/30fps video camera and does not need AR during recording.
@MainActor
final class VideoRelightingProcessor: VideoRelightingProcessing {
  private let estimator: any NormalEstimating
  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  init(estimator: any NormalEstimating) {
    self.estimator = estimator
  }

  func process(
    inputURL: URL,
    parameters: RelightingParameters,
    progress: @escaping (VideoRelightingProgress) async -> Void
  ) async throws -> URL {
    let asset = AVURLAsset(url: inputURL)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw VideoRelightingError.videoTrackMissing
    }
    let sourceSize = try await videoTrack.load(.naturalSize)
    let sourceTransform = try await videoTrack.load(.preferredTransform)
    let orientedSize = sourceSize.applying(sourceTransform)
    let width = max(Int(abs(orientedSize.width).rounded()), 2)
    let height = max(Int(abs(orientedSize.height).rounded()), 2)
    guard width <= 1280, height <= 720 else {
      throw VideoRelightingError.processingFailed("Video must be recorded at 720p or lower.")
    }
    let nominalRate = max(try await videoTrack.load(.nominalFrameRate), 1)
    let duration = try await asset.load(.duration)
    let estimatedFrames = max(Int((duration.seconds * Double(nominalRate)).rounded()), 1)

    let reader = try AVAssetReader(asset: asset)
    let readerVideo = AVAssetReaderTrackOutput(
      track: videoTrack,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      ]
    )
    readerVideo.alwaysCopiesSampleData = false
    guard reader.canAdd(readerVideo) else { throw VideoRelightingError.readerSetupFailed }
    reader.add(readerVideo)

    let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
    let requestedAudioOutput = audioTrack.map {
      AVAssetReaderTrackOutput(track: $0, outputSettings: nil)
    }
    let readerAudio: AVAssetReaderTrackOutput?
    if let requestedAudioOutput, reader.canAdd(requestedAudioOutput) {
      reader.add(requestedAudioOutput)
      readerAudio = requestedAudioOutput
    } else {
      readerAudio = nil
    }

    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lighting-relit-\(UUID().uuidString).mov"
    )
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 5_000_000,
        AVVideoExpectedSourceFrameRateKey: 30,
        AVVideoMaxKeyFrameIntervalKey: 30,
      ],
    ]
    let writerVideo = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    writerVideo.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: writerVideo,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
    )
    guard writer.canAdd(writerVideo) else { throw VideoRelightingError.writerSetupFailed }
    writer.add(writerVideo)
    let requestedAudioInput: AVAssetWriterInput? = readerAudio.map { _ in
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
      input.expectsMediaDataInRealTime = false
      return input
    }
    let writerAudio: AVAssetWriterInput?
    if let requestedAudioInput, writer.canAdd(requestedAudioInput) {
      writer.add(requestedAudioInput)
      writerAudio = requestedAudioInput
    } else {
      writerAudio = nil
    }

    guard reader.startReading(), writer.startWriting() else {
      throw VideoRelightingError.readerSetupFailed
    }
    writer.startSession(atSourceTime: .zero)

    var processedFrames = 0
    while let sample = readerVideo.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
            let sourceImage = makeCGImage(from: sourceBuffer, transform: sourceTransform) else {
        throw VideoRelightingError.frameConversionFailed
      }
      let analysis = try await estimator.estimate(
        image: sourceImage,
        computePreference: .automatic,
        progress: { _ in }
      )
      let resources = try MetalRelightingResources(
        originalImage: analysis.originalImage,
        normals: analysis.normals,
        mask: analysis.foregroundMask
      )
      let relitImage = try await resources.export(parameters: parameters)
      await waitUntilReady(writerVideo)
      guard let destination = adaptor.pixelBufferPool.flatMap(makePixelBuffer) else {
        throw VideoRelightingError.writerSetupFailed
      }
      try draw(relitImage, into: destination, width: width, height: height)
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      guard adaptor.append(destination, withPresentationTime: time) else {
        throw VideoRelightingError.appendFailed
      }
      processedFrames += 1
      await progress(VideoRelightingProgress(
        processedFrames: processedFrames,
        estimatedFrameCount: estimatedFrames
      ))
    }
    guard reader.status == .completed else {
      throw VideoRelightingError.processingFailed(reader.error?.localizedDescription ?? "The video reader stopped early.")
    }
    writerVideo.markAsFinished()

    if let readerAudio, let writerAudio {
      while let sample = readerAudio.copyNextSampleBuffer() {
        await waitUntilReady(writerAudio)
        guard writerAudio.append(sample) else { throw VideoRelightingError.appendFailed }
      }
      writerAudio.markAsFinished()
    }

    await writer.finishWriting()
    guard writer.status == .completed else {
      throw VideoRelightingError.processingFailed(writer.error?.localizedDescription ?? "The export writer stopped early.")
    }
    await progress(VideoRelightingProgress(
      processedFrames: processedFrames,
      estimatedFrameCount: max(processedFrames, estimatedFrames)
    ))
    return outputURL
  }

  private func makeCGImage(from buffer: CVPixelBuffer, transform: CGAffineTransform) -> CGImage? {
    let image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
    let movedImage = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    return ciContext.createCGImage(movedImage, from: movedImage.extent)
  }

  private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    return CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess ? buffer : nil
  }

  private func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) throws {
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
      throw VideoRelightingError.frameConversionFailed
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
              | CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else { throw VideoRelightingError.frameConversionFailed }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }

  private func waitUntilReady(_ input: AVAssetWriterInput) async {
    while !input.isReadyForMoreMediaData {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }
}
