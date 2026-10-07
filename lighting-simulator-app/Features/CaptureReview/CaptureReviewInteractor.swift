import Combine
import Foundation

@MainActor
protocol CaptureReviewInteractorProtocol: AnyObject {
    var arService: ARSessionService { get }
    var statePublisher: AnyPublisher<CaptureReviewEntity, Never> { get }
    func capture() async throws
    func retake()
    func proceed(projectName: String) async throws -> UUID
}

@MainActor
final class CaptureReviewInteractor: CaptureReviewInteractorProtocol {
    let arService: ARSessionService
    private let store: AppSessionStore
    private let state = CurrentValueSubject<CaptureReviewEntity, Never>(.init())

    init(
        store: AppSessionStore,
        arService: ARSessionService
    ) {
        self.store = store
        self.arService = arService
    }

    var statePublisher: AnyPublisher<CaptureReviewEntity, Never> {
        state.eraseToAnyPublisher()
    }

    func capture() async throws {
        state.send(CaptureReviewEntity(draft: nil, phase: .capturing, canCapture: false))

        do {
            // One ARFrame owns all shutter-time data: high-resolution pixels,
            // camera pose, and intrinsics. There is no second camera session to
            // warm up after the user presses Capture.
            let photo = try await arService.captureHighResolutionPhoto()
            arService.stopAndRelease()
            let preview = try ImageOrientationNormalizer(
                maximumPixelDimension: ImageOrientationNormalizer.editorProxyMaximumPixelDimension
            )
                .normalize(data: photo.data)
            state.send(CaptureReviewEntity(
                draft: CapturedPhotoDraft(
                    data: photo.data,
                    preview: preview,
                    cameraTransform: SpatialTransform(photo.cameraTransform),
                    cameraCalibration: photo.calibration
                ),
                phase: .idle,
                canCapture: false
            ))
        } catch {
            state.send(.init())
            throw error
        }
    }

    func retake() {
        state.send(.init())
        Task {
            try? await arService.start(resetTracking: false)
        }
    }

    func proceed(projectName: String) async throws -> UUID {
        guard let draft = state.value.draft,
              let project = store.currentProject,
              let subject = project.subject,
              !project.lights.isEmpty else { throw ARServiceError.noCurrentFrame }
        state.send(CaptureReviewEntity(draft: draft, phase: .savingProject, canCapture: false))

        do {
            let focusPoint = SpatialMath.captureFramingTarget(
                subjectBase: subject.position.simd,
                cameraTransform: draft.cameraTransform.matrix
            )
            let capturedLights = project.lights.map { original -> VirtualLight in
                var light = original
                light.targetPosition = SpatialVector(focusPoint)
                light.targetSurfaceNormal = nil
                light.panOffsetDegrees = 0
                light.tiltOffsetDegrees = 0
                if let direction = SpatialMath.direction(from: light.position.simd, to: focusPoint),
                   let orientation = SpatialMath.orientation(facing: direction) {
                    light.orientation = SpatialQuaternion(orientation)
                }
                return light
            }
            let snapshot = SpatialPlanSnapshot(
                projectID: project.id,
                cameraTransform: draft.cameraTransform,
                cameraCalibration: draft.cameraCalibration,
                subjectPosition: subject.position,
                lights: capturedLights
            )
            // Capture data and the value-only snapshot are complete. Drop the
            // live camera before persistence and Core ML allocate memory.
            arService.stopAndRelease()
            var shot = Shot(
                projectID: project.id,
                imageFileName: nil,
                timestamp: Date(),
                cameraTransform: snapshot.cameraTransform,
                cameraCalibration: snapshot.cameraCalibration,
                subjectPosition: snapshot.subjectPosition,
                lights: snapshot.lights
            )
            shot.imageFileName = try await store.repository.saveImageData(
                draft.data, shotID: shot.id
            )
            try await store.commitCurrentDraft(named: projectName, shot: shot)
            store.editorPayload = EditorPayload(
                shotID: shot.id,
                photo: draft.preview,
                plan: snapshot,
                editState: shot.editState,
                cachedAnalysis: nil
            )

            return shot.id
        } catch {
            state.send(CaptureReviewEntity(
                draft: draft,
                phase: .idle,
                canCapture: false
            ))
            throw error
        }
    }
}
