import ARKit
import Combine

@MainActor
protocol SubjectPlacementInteractorProtocol: AnyObject {
    var arService: ARSessionService { get }
    var statePublisher: AnyPublisher<SubjectPlacementEntity, Never> { get }
    var debugSettings: DebugSettings { get }
    func start() async throws
    func placeSubject() throws
}

@MainActor
final class SubjectPlacementInteractor: SubjectPlacementInteractorProtocol {
    let arService: ARSessionService
    private let store: AppSessionStore

    init(store: AppSessionStore, arService: ARSessionService) {
        self.store = store
        self.arService = arService
    }

    var debugSettings: DebugSettings { store.debugSettings }

    func start() async throws {
        try await arService.start(resetTracking: store.consumeWorldResetRequest())
    }

    var statePublisher: AnyPublisher<SubjectPlacementEntity, Never> {
        Publishers.CombineLatest3(store.$currentProject, arService.$cameraTransform, arService.$trackingDescription)
            .map { [capabilities = arService.capabilities] project, cameraTransform, tracking in
                let camera = cameraTransform?.translation
                let subject = project?.subject
                let distance = camera.flatMap { camera in
                    subject.map { SpatialMath.distance(camera, $0.position.simd) }
                }
                return SubjectPlacementEntity(
                    subject: subject,
                    debugSnapshot: SpatialDebugSnapshot(
                        tracking: tracking,
                        camera: camera.map(SpatialVector.init),
                        subject: subject?.position,
                        light: project?.primaryLight?.position,
                        cameraToSubject: distance,
                        lightToSubject: nil,
                        capabilities: capabilities
                    )
                )
            }
            .eraseToAnyPublisher()
    }

    func placeSubject() throws {
        let position = try arService.raycastFromCameraCenter(alignment: .horizontal, context: "subject placement")
        store.updateCurrent { $0.subject = PlannedSubject(position: SpatialVector(position)) }
    }
}
