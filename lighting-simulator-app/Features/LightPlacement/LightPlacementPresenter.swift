import Combine
import Foundation

@MainActor
final class LightPlacementPresenter: ObservableObject {
    @Published private(set) var entity: LightPlacementEntity
    @Published var errorMessage: String?

    let arService: ARSessionService
    let debugSettings: DebugSettings
    private let interactor: LightPlacementInteractorProtocol
    private let router: LightPlacementRouting
    private var cancellables = Set<AnyCancellable>()

    init(interactor: LightPlacementInteractorProtocol, router: LightPlacementRouting) {
        self.interactor = interactor
        self.router = router
        arService = interactor.arService
        debugSettings = interactor.debugSettings
        entity = LightPlacementEntity(
            subject: nil,
            lights: [],
            selectedLightID: nil,
            placementPreview: nil,
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

    func selectLight(_ id: UUID) { interactor.selectLight(id: id) }
    func placeLight() { perform(interactor.placeLight) }
    func moveLight() { perform(interactor.moveSelectedLight) }
    func removeLight() { interactor.removeSelectedLight() }

    func continueToCapture() {
        guard entity.isReadyForPreview else {
            errorMessage = "Place at least one lamp before opening the camera."
            return
        }
        router.showCapture()
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { errorMessage = error.localizedDescription }
    }
}
