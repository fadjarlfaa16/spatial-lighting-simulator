import Combine
import Foundation

@MainActor
final class CaptureReviewPresenter: ObservableObject {
    @Published private(set) var entity = CaptureReviewEntity()
    @Published var errorMessage: String?
    @Published var projectName = ""
    @Published var isNamingProject = false
    let arService: ARSessionService
    private let interactor: CaptureReviewInteractorProtocol
    private let router: CaptureReviewRouting
    private var cancellables = Set<AnyCancellable>()

    init(interactor: CaptureReviewInteractorProtocol, router: CaptureReviewRouting) {
        self.interactor = interactor
        self.router = router
        arService = interactor.arService
        interactor.statePublisher.sink { [weak self] in self?.entity = $0 }
            .store(in: &cancellables)
    }

    func capture() {
        Task {
            do { try await interactor.capture() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func retake() { interactor.retake() }
    func requestProceed() {
        guard entity.phase != .savingProject else { return }
        isNamingProject = true
    }

    func proceed() {
        let cleanedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            errorMessage = ProjectSessionError.projectNameRequired.localizedDescription
            return
        }
        isNamingProject = false
        Task {
            do {
                router.showEditor(
                    shotID: try await interactor.proceed(projectName: cleanedName)
                )
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
