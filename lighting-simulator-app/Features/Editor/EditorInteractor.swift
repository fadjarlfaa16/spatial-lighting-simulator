import Combine
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

@MainActor
protocol EditorInteractorProtocol: AnyObject {
    var statePublisher: AnyPublisher<EditorEntity, Never> { get }
    func start() async
    func selectLight(_ id: UUID)
    func adjustAim(panDelta: Float, tiltDelta: Float)
    func updateHeight(_ value: Float)
    func updateIntensity(_ value: Float)
    func updateKelvin(_ value: Float)
    func updateBeamAngle(_ value: Float)
    func updateFalloff(_ value: Float)
    func updateAmbient(_ value: Float)
    func updateDiffuse(_ value: Float)
    func updateSpecular(_ value: Float)
    func updateShininess(_ value: Float)
    func setDisplayMode(_ value: EditorDisplayMode)
    func toggleCleanPreview()
    func flushEdits() async
    func export() async throws
}

@MainActor
final class EditorInteractor: EditorInteractorProtocol {
    private let store: AppSessionStore
    private let estimator: any NormalEstimating
    private let shotID: UUID
    private let state = CurrentValueSubject<EditorEntity, Never>(.init())
    private var started = false
    private var pendingPersistence: Task<Void, Never>?

    init(store: AppSessionStore, estimator: any NormalEstimating, shotID: UUID) {
        self.store = store
        self.estimator = estimator
        self.shotID = shotID
        if let payload = store.editorPayload, payload.shotID == shotID {
            var entity = EditorEntity()
            entity.photo = payload.photo
            entity.plan = payload.plan
            entity.parameters = SpatialToImageLightingMapper.makeParameters(from: payload.plan)
            payload.editState.apply(to: &entity.parameters)
            entity.selectedLightID = payload.plan.lights.first?.id
            if let cache = payload.cachedAnalysis {
                do {
                    let renderer = SapiensResultRenderer()
                    entity.normalVisualization = try renderer.makeNormalMap(from: cache.normals)
                    if let mask = cache.mask {
                        entity.maskVisualization = try renderer.makeMask(from: mask)
                    }
                    entity.resources = try MetalRelightingResources(
                        originalImage: payload.photo,
                        normals: cache.normals,
                        mask: cache.mask
                    )
                    entity.inferenceSummary = "Cached analysis · no inference"
                    entity.phase = .completed
                    started = true
                } catch {
                    entity.phase = .idle
                }
            }
            state.send(entity)
        }
    }

    var statePublisher: AnyPublisher<EditorEntity, Never> { state.eraseToAnyPublisher() }

    func start() async {
        guard !started, let photo = state.value.photo else { return }
        started = true
        do {
            let result = try await estimator.estimate(
                image: photo,
                computePreference: .automatic
            ) { [weak self] phase in
                await self?.setPhase(phase)
            }
            await store.saveAnalysisCache(
                shotID: shotID,
                normals: result.normals,
                mask: result.foregroundMask
            )
            mutate {
                $0.phase = .preparingGPU
                $0.normalVisualization = result.normalVisualization
                if let mask = result.foregroundMask {
                    $0.maskVisualization = try? SapiensResultRenderer().makeMask(from: mask)
                }
                $0.resources = try? MetalRelightingResources(
                    originalImage: result.originalImage,
                    normals: result.normals,
                    mask: result.foregroundMask
                )
                $0.inferenceSummary = "\(result.computeUnits) · \(Self.seconds(result.inferenceDuration)) s"
                $0.phase = $0.resources == nil
                    ? .failed("Texture GPU tidak dapat dibuat.") : .completed
            }
        } catch {
            mutate { $0.phase = .failed(error.localizedDescription) }
        }
    }

    func selectLight(_ id: UUID) { mutate { $0.selectedLightID = id } }

    func adjustAim(panDelta: Float, tiltDelta: Float) {
        mutatePlanLight { light, plan in
            guard let target = light.targetPosition?.simd else { return }
            let nextPan = min(max(light.panOffset + panDelta, -65), 65)
            let nextTilt = min(max(light.tiltOffset + tiltDelta, -65), 65)
            let appliedPan = nextPan - light.panOffset
            let appliedTilt = nextTilt - light.tiltOffset
            let axes = SpatialMath.capturedScreenAxes(
                cameraTransform: plan.cameraTransform.matrix,
                orientation: plan.cameraCalibration?.imageOrientation ?? .up
            )
            let distance = max(simd_distance(light.position.simd, target), 0.05)
            let shiftedTarget = target
                + axes.right * (distance * tan(appliedPan * .pi / 180))
                + axes.down * (distance * tan(appliedTilt * .pi / 180))
            guard let direction = SpatialMath.direction(
                from: light.position.simd,
                to: shiftedTarget
            ), let orientation = SpatialMath.orientation(facing: direction) else { return }
            light.panOffsetDegrees = nextPan
            light.tiltOffsetDegrees = nextTilt
            light.targetPosition = SpatialVector(shiftedTarget)
            light.orientation = SpatialQuaternion(orientation)
        }
        schedulePersistence()
    }

    func updateHeight(_ value: Float) {
        mutatePlanLight { light, _ in
            light.setHeight(value)
            if let target = light.targetPosition?.simd,
               let direction = SpatialMath.direction(from: light.position.simd, to: target),
               let orientation = SpatialMath.orientation(facing: direction) {
                light.orientation = SpatialQuaternion(orientation)
            }
        }
        schedulePersistence()
    }
    func updateIntensity(_ value: Float) {
        mutatePlanLight { light, _ in light.intensity = min(max(value, 0), 100) }
        schedulePersistence()
    }
    func updateKelvin(_ value: Float) {
        mutatePlanLight { light, _ in light.kelvin = min(max(value, 2_700), 10_000) }
        schedulePersistence()
    }
    func updateBeamAngle(_ value: Float) {
        mutatePlanLight { light, _ in light.beamAngle = min(max(value, 10), 120) }
        schedulePersistence()
    }

    func updateFalloff(_ value: Float) {
        mutate { entity in
            guard let index = selectedRenderIndex(in: entity) else { return }
            entity.parameters.lights[index].falloffSoftness = min(max(value, 0.02), 1)
        }
        schedulePersistence()
    }
    func updateAmbient(_ value: Float) {
        mutate { $0.parameters.ambientIntensity = value }
        schedulePersistence()
    }
    func updateDiffuse(_ value: Float) {
        mutate { $0.parameters.diffuseStrength = value }
        schedulePersistence()
    }
    func updateSpecular(_ value: Float) {
        mutate { $0.parameters.specularStrength = value }
        schedulePersistence()
    }
    func updateShininess(_ value: Float) {
        mutate { $0.parameters.specularShininess = value }
        schedulePersistence()
    }
    func setDisplayMode(_ value: EditorDisplayMode) { mutate { $0.displayMode = value } }
    func toggleCleanPreview() { mutate { $0.isCleanPreview.toggle() } }

    func flushEdits() async {
        pendingPersistence?.cancel()
        pendingPersistence = nil
        await persistCurrentEditorState()
    }

    func export() async throws {
        await flushEdits()
        guard let resources = state.value.resources else {
            throw MetalRelightingError.unavailable
        }
        mutate { $0.isExporting = true }
        defer { mutate { $0.isExporting = false } }
        let parameters = state.value.parameters
        let image = try await resources.export(parameters: parameters)
        let data = try Self.pngData(image)
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw MetalRelightingError.execution("Izin menambahkan foto ditolak.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    private func mutatePlanLight(_ body: (inout VirtualLight, SpatialPlanSnapshot) -> Void) {
        mutate { entity in
            guard var plan = entity.plan,
                  let id = entity.selectedLightID,
                  let index = plan.lights.firstIndex(where: { $0.id == id }) else { return }
            let previousFalloffs = Dictionary(
                uniqueKeysWithValues: entity.parameters.lights.map { ($0.id, $0.falloffSoftness) }
            )
            let contextPlan = plan
            body(&plan.lights[index], contextPlan)
            entity.plan = plan
            var mapped = SpatialToImageLightingMapper.makeParameters(from: plan)
            mapped.ambientIntensity = entity.parameters.ambientIntensity
            mapped.diffuseStrength = entity.parameters.diffuseStrength
            mapped.specularStrength = entity.parameters.specularStrength
            mapped.specularShininess = entity.parameters.specularShininess
            for renderIndex in mapped.lights.indices {
                if let previous = previousFalloffs[mapped.lights[renderIndex].id] {
                    mapped.lights[renderIndex].falloffSoftness = previous
                }
            }
            entity.parameters = mapped
        }
    }

    private func selectedRenderIndex(in entity: EditorEntity) -> Int? {
        guard let id = entity.selectedLightID else { return nil }
        return entity.parameters.lights.firstIndex { $0.id == id }
    }

    private func schedulePersistence() {
        pendingPersistence?.cancel()
        pendingPersistence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistCurrentEditorState()
        }
    }

    private func persistCurrentEditorState() async {
        guard let plan = state.value.plan else { return }
        await store.saveEditorState(
            shotID: shotID,
            plan: plan,
            parameters: state.value.parameters
        )
    }

    private func mutate(_ body: (inout EditorEntity) -> Void) {
        var value = state.value
        body(&value)
        state.send(value)
    }

    private func setPhase(_ phase: AnalysisPhase) {
        mutate { $0.phase = phase }
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f", duration.components.seconds == 0
            ? Double(duration.components.attoseconds) / 1e18
            : Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw ResultRenderingError.imageCreationFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ResultRenderingError.imageCreationFailed
        }
        return data as Data
    }
}
