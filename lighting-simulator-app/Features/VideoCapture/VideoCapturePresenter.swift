import Combine
import Foundation

@MainActor
final class VideoCapturePresenter: ObservableObject {
  @Published private(set) var entity = VideoCaptureEntity()
  @Published var errorMessage: String?

  let recorder: VideoRecordingService
  private let interactor: VideoCaptureInteractorProtocol
  private let router: VideoCaptureRouting
  private var cancellables = Set<AnyCancellable>()

  init(interactor: VideoCaptureInteractorProtocol, router: VideoCaptureRouting) {
    self.interactor = interactor
    self.router = router
    recorder = interactor.recorder
    interactor.statePublisher
      .sink { [weak self] in self?.entity = $0 }
      .store(in: &cancellables)
  }

  func start() async { await interactor.start() }

  func toggleRecording() {
    if entity.isRecording {
      Task {
        do { try await interactor.finishRecordingAndRelight() }
        catch { errorMessage = error.localizedDescription }
      }
    } else {
      guard case .ready = entity.phase else { return }
      do { try interactor.beginRecording() }
      catch { errorMessage = error.localizedDescription }
    }
  }

  func toggleCamera() {
    do { try recorder.toggleCamera() }
    catch { errorMessage = error.localizedDescription }
  }

  func saveOriginalVideo() {
    Task {
      do { try await interactor.saveOriginalVideo() }
      catch { errorMessage = error.localizedDescription }
    }
  }

  func saveRelitVideo() {
    Task {
      do { try await interactor.saveRelitVideo() }
      catch { errorMessage = error.localizedDescription }
    }
  }

  func done() { router.showProjects() }
  func stop() { Task { await interactor.stop() } }
}
