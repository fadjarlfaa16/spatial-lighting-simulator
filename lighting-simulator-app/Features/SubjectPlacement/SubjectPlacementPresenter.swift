import Combine
import Foundation

@MainActor
final class SubjectPlacementPresenter: ObservableObject {
    @Published private(set) var entity: SubjectPlacementEntity
    @Published var errorMessage: String?

    let arService: ARSessionService
    let debugSettings: DebugSettings
    private let interactor: SubjectPlacementInteractorProtocol
    private let router: SubjectPlacementRouting
    private var cancellables = Set<AnyCancellable>()

    init(interactor: SubjectPlacementInteractorProtocol, router: SubjectPlacementRouting) {
        self.interactor = interactor
        self.router = router
        arService = interactor.arService
        debugSettings = interactor.debugSettings
        entity = SubjectPlacementEntity(
            subject: nil,
            debugSnapshot: SpatialDebugSnapshot(
                tracking: "Not started", camera: nil, subject: nil, light: nil,
                cameraToSubject: nil, lightToSubject: nil,
                capabilities: interactor.arService.capabilities
            )
        )
        interactor.statePublisher
            .sink { [weak self] in self?.entity = $0 }
            .store(in: &cancellables)
    }

    func placeSubject() {
        do { try interactor.placeSubject() }
        catch { errorMessage = error.localizedDescription }
    }

    func start() async {
        do { try await interactor.start() }
        catch { errorMessage = error.localizedDescription }
    }

    func continueToLight() {
        guard entity.subject != nil else {
            errorMessage = "Place the planned subject before continuing."
            return
        }
        router.showLightPlacement()
    }
}
