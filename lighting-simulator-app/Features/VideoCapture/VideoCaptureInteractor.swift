import Combine
import Foundation
import Photos

@MainActor
protocol VideoCaptureInteractorProtocol: AnyObject {
  var recorder: VideoRecordingService { get }
  var statePublisher: AnyPublisher<VideoCaptureEntity, Never> { get }
  func start() async
  func beginRecording() throws
  func finishRecordingAndRelight() async throws
  func saveOriginalVideo() async throws
  func saveRelitVideo() async throws
  func stop() async
}

@MainActor
final class VideoCaptureInteractor: VideoCaptureInteractorProtocol {
  let recorder: VideoRecordingService
  private let store: AppSessionStore
  private let processor: any VideoRelightingProcessing
  private let shotID: UUID
  private let state = CurrentValueSubject<VideoCaptureEntity, Never>(.init())

  init(
    store: AppSessionStore,
    recorder: VideoRecordingService,
    processor: any VideoRelightingProcessing,
    shotID: UUID
  ) {
    self.store = store
    self.recorder = recorder
    self.processor = processor
    self.shotID = shotID
  }

  var statePublisher: AnyPublisher<VideoCaptureEntity, Never> { state.eraseToAnyPublisher() }

  func start() async {
    state.send(VideoCaptureEntity(phase: .preparingCamera))
    do {
      try await recorder.start()
      state.send(VideoCaptureEntity(phase: .ready))
    } catch {
      state.send(VideoCaptureEntity(phase: .failed(error.localizedDescription)))
    }
  }

  func beginRecording() throws {
    try recorder.beginRecording()
    state.send(VideoCaptureEntity(phase: .recording, isRecording: true))
  }

  func finishRecordingAndRelight() async throws {
    let temporarySourceURL: URL
    do {
      temporarySourceURL = try await recorder.finishRecording()
    } catch {
      await recorder.stopAndRelease()
      sendFailure(error)
      throw error
    }

    // The movie delegate has finalized the source file. The camera is no
    // longer needed and must release its session before Core ML/Metal starts.
    await recorder.stopAndRelease()
    var processing = state.value
    processing.phase = .processing(
      VideoRelightingProgress(processedFrames: 0, estimatedFrameCount: 1)
    )
    processing.isRecording = false
    state.send(processing)
    defer { try? FileManager.default.removeItem(at: temporarySourceURL) }

    do {
      let sourceURL = try await store.persistVideo(
        from: temporarySourceURL,
        shotID: shotID,
        kind: .source
      )
      var sourcePersisted = state.value
      sourcePersisted.originalVideoURL = sourceURL
      state.send(sourcePersisted)

      let parameters = try lightingParameters()
      let outputURL = try await processor.process(
        inputURL: sourceURL,
        parameters: parameters,
        progress: { progress in
          var next = self.state.value
          next.phase = .processing(progress)
          self.state.send(next)
        }
      )
      defer { try? FileManager.default.removeItem(at: outputURL) }
      let relitURL = try await store.persistVideo(
        from: outputURL,
        shotID: shotID,
        kind: .relit
      )
      var completed = state.value
      completed.phase = .completed
      completed.relitVideoURL = relitURL
      state.send(completed)
    } catch {
      sendFailure(error)
      throw error
    }
  }

  func saveOriginalVideo() async throws {
    guard let url = state.value.originalVideoURL else {
      throw VideoRelightingError.processingFailed("The original video is not ready.")
    }
    try await saveVideo(url, kind: .source)
  }

  func saveRelitVideo() async throws {
    guard let url = state.value.relitVideoURL else {
      throw VideoRelightingError.processingFailed("The relit video is not ready.")
    }
    try await saveVideo(url, kind: .relit)
  }

  func stop() async { await recorder.stopAndRelease() }

  private func lightingParameters() throws -> RelightingParameters {
    guard let shot = store.shot(id: shotID),
          let project = store.currentProject,
          project.effectiveMediaKind == .video else {
      throw ProjectSessionError.missingProject
    }
    let plan = SpatialPlanSnapshot(
      projectID: project.id,
      cameraTransform: shot.cameraTransform,
      cameraCalibration: shot.cameraCalibration,
      subjectPosition: shot.subjectPosition,
      lights: shot.lights
    )
    var parameters = SpatialToImageLightingMapper.makeParameters(from: plan)
    shot.editState.apply(to: &parameters)
    return parameters
  }

  private func saveVideo(_ url: URL, kind: ProjectVideoKind) async throws {
    var saving = state.value
    switch kind {
    case .source: saving.originalSaveStatus = .saving
    case .relit: saving.relitSaveStatus = .saving
    }
    state.send(saving)

    do {
      try await saveToPhotos(url)
      var saved = state.value
      switch kind {
      case .source: saved.originalSaveStatus = .saved
      case .relit: saved.relitSaveStatus = .saved
      }
      state.send(saved)
    } catch {
      var reset = state.value
      switch kind {
      case .source: reset.originalSaveStatus = .idle
      case .relit: reset.relitSaveStatus = .idle
      }
      state.send(reset)
      throw error
    }
  }

  private func saveToPhotos(_ url: URL) async throws {
    let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard authorization == .authorized || authorization == .limited else {
      throw MetalRelightingError.execution("Permission to add videos was denied.")
    }
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
    }
  }

  private func sendFailure(_ error: Error) {
    var failed = state.value
    failed.phase = .failed(error.localizedDescription)
    failed.isRecording = false
    state.send(failed)
  }
}
