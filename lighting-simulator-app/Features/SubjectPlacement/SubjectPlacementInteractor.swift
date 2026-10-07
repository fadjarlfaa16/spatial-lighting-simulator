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
        let position: SIMD3<Float>
        if arService.cameraPosition == .front {
            guard let face = arService.facePosition else {
                throw ARServiceError.raycastFailed("No face detected for subject placement.")
            }
            position = face
        } else {
            position = try arService.raycastFromCameraCenter(alignment: .horizontal, context: "subject placement")
        }
        guard let cameraTransform = arService.session.currentFrame?.camera.transform else {
            throw ARServiceError.noCurrentFrame
        }
        let subject = PlannedSubject(position: SpatialVector(position))
        let lights = InitialLightingPlanFactory.makeLights(
            subjectBase: position,
            cameraTransform: cameraTransform
        )
        store.updateCurrent {
            $0.subject = subject
            $0.lights = lights
        }
    }
}
