import Combine
import Foundation

@MainActor
final class EditorPresenter: ObservableObject {
    @Published private(set) var entity = EditorEntity()
    @Published var message: String?
    private let interactor: EditorInteractorProtocol
    private let router: EditorRouting
    private var cancellables = Set<AnyCancellable>()

    init(interactor: EditorInteractorProtocol, router: EditorRouting) {
        self.interactor = interactor
        self.router = router
        interactor.statePublisher.sink { [weak self] in self?.entity = $0 }
            .store(in: &cancellables)
    }

    func start() async { await interactor.start() }
    func selectLight(_ id: UUID) { interactor.selectLight(id) }
    func aim(translation: CGSize) {
        interactor.adjustAim(
            panDelta: Float(translation.width) * 0.035,
            tiltDelta: Float(translation.height) * 0.035
        )
    }
    func height(_ value: Float) { interactor.updateHeight(value) }
    func intensity(_ value: Float) { interactor.updateIntensity(value) }
    func kelvin(_ value: Float) { interactor.updateKelvin(value) }
    func beam(_ value: Float) { interactor.updateBeamAngle(value) }
    func falloff(_ value: Float) { interactor.updateFalloff(value) }
    func ambient(_ value: Float) { interactor.updateAmbient(value) }
    func diffuse(_ value: Float) { interactor.updateDiffuse(value) }
    func specular(_ value: Float) { interactor.updateSpecular(value) }
    func shininess(_ value: Float) { interactor.updateShininess(value) }
    func haze(_ value: Float) { interactor.updateHaze(value) }
    func display(_ value: EditorDisplayMode) { interactor.setDisplayMode(value) }
    func preview() { interactor.toggleCleanPreview() }
    func done() {
        Task {
            await interactor.flushEdits()
            router.showProjects()
        }
    }
    func export() {
        Task {
            do { try await interactor.export(); message = "Hasil tersimpan ke Photos." }
            catch { message = error.localizedDescription }
        }
    }
}
