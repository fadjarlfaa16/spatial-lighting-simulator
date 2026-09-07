import CoreGraphics
import Foundation
import ImageIO
import simd
import Testing
import UniformTypeIdentifiers
@testable import lighting_simulator_app

struct LightingSimulatorTests {
    @Test func snapshotMeasuresEveryRelevantPair() {
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(0, 1.5, 0, 1)
        let subject = SpatialVector(x: 0, y: 0, z: -3)
        let lightA = fixture(name: "Key", position: SIMD3(-2, 2, -2), target: subject.simd)
        let lightB = fixture(name: "Fill", position: SIMD3(2, 2, -2), target: subject.simd)
        let snapshot = SpatialPlanSnapshot(
            projectID: UUID(), cameraTransform: SpatialTransform(camera),
            subjectPosition: subject, lights: [lightA, lightB]
        )

        #expect(snapshot.distances.count == 6)
        #expect(snapshot.distances.allSatisfy { $0.meters.isFinite && $0.meters > 0 })
        #expect(snapshot.distances.contains { $0.fromID == "light-1" && $0.toID == "light-2" })
    }

    @Test func aimChangesOrientationButNeverFixturePosition() throws {
        let target = SIMD3<Float>(0, 0, -3)
        var light = fixture(name: "Key", position: SIMD3(1, 2, 0), target: target)
        let fixed = light.position
        light.panOffsetDegrees = 18
        light.tiltOffsetDegrees = -7
        light.orientation = SpatialQuaternion(try #require(SpatialMath.orientationWithAimOffsets(for: light)))

        #expect(light.position == fixed)
        #expect(abs(SpatialMath.effectiveDirection(for: light).x) > 0.01)
    }

    @Test func rendererMappingUsesMeasuredMeters() {
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(0, 1, 0, 1)
        let subject = SpatialVector(x: 0, y: 0, z: -3)
        let light = fixture(name: "Key", position: SIMD3(0, 2, -1), target: subject.simd)
        let snapshot = SpatialPlanSnapshot(
            projectID: UUID(), cameraTransform: SpatialTransform(camera),
            subjectPosition: subject, lights: [light]
        )
        let parameters = SpatialToImageLightingMapper.makeParameters(from: snapshot)
        let expected = simd_distance(light.position.simd, subject.simd)
        #expect(abs(parameters.lights[0].distanceMeters - expected) < 0.0001)
    }

    @Test func capturedIntrinsicsProjectTheOpticalCenter() {
        let calibration = CameraCalibration(
            fx: 1_000, fy: 1_000, cx: 960, cy: 720,
            sensorWidth: 1_920, sensorHeight: 1_440,
            imageOrientation: .up
        )
        let subject = SpatialVector(x: 0, y: 0, z: -3)
        let target = SIMD3<Float>(0, 1, -3)
        let light = fixture(name: "Key", position: SIMD3(1, 2, -1), target: target)
        let snapshot = SpatialPlanSnapshot(
            projectID: UUID(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            cameraCalibration: calibration,
            subjectPosition: subject,
            lights: [light]
        )

        let mapped = SpatialToImageLightingMapper.makeParameters(from: snapshot).lights[0]
        #expect(abs(mapped.normalizedPosition.x - 0.5) < 0.0001)
        #expect(abs(mapped.normalizedPosition.y - (720 - 1_000.0 / 3) / 1_440) < 0.0001)
    }

    @Test func capturedScreenAxesFollowFingerDirection() {
        let up = SpatialMath.capturedScreenAxes(
            cameraTransform: matrix_identity_float4x4,
            orientation: .up
        )
        #expect(up.right.x > 0.99)
        #expect(up.down.y < -0.99)

        let rotated = SpatialMath.capturedScreenAxes(
            cameraTransform: matrix_identity_float4x4,
            orientation: .down
        )
        #expect(rotated.right.x < -0.99)
        #expect(rotated.down.y > 0.99)
    }

    @Test func jpegExifOrientationIsMappedExactlyOnce() {
        #expect(CapturedImageOrientation(exifRawValue: 1) == .up)
        #expect(CapturedImageOrientation(exifRawValue: 3) == .down)
        #expect(CapturedImageOrientation(exifRawValue: 8) == .left)
        #expect(CapturedImageOrientation(exifRawValue: 6) == .right)

        let point = SIMD2<Float>(0.2, 0.3)
        #expect(CapturedImageOrientation.up.orient(normalized: point) == point)
        #expect(CapturedImageOrientation.down.orient(normalized: point) == SIMD2(0.8, 0.7))
    }

    @Test func changingFixtureHeightPreservesFloorCoordinate() {
        var light = fixture(
            name: "Key",
            position: SIMD3(2, 1.8, -1),
            target: SIMD3(0, 1, -3)
        )
        light.setHeight(3.2)
        #expect(light.position.x == 2)
        #expect(light.position.z == -1)
        #expect(abs(light.position.y - 3.2) < 0.0001)
    }

    @Test func proceededPhotoIsBoundedBeforeInference() throws {
        let input = try makeImageData(width: 4_000, height: 2_000)
        let output = try PhotoCompressor().compress(input, maximumDimension: 1_024, quality: 0.8)
        #expect(max(output.image.width, output.image.height) <= 1_024)
        #expect(output.jpegData.count > 100)
    }

    @Test @MainActor func legacyShotWithoutEditorValuesUsesSafeDefaults() throws {
        let projectID = UUID()
        let shot = Shot(
            projectID: projectID,
            imageFileName: "photo.jpg",
            timestamp: Date(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(x: 0, y: 0, z: -2),
            lights: []
        )
        let encoded = try JSONEncoder().encode(shot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "editState")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Shot.self, from: legacyData)
        #expect(decoded.editState == .initial)
    }

    @Test func savedEditorValuesRestoreGlobalsAndPerLightFalloff() {
        let lightID = UUID()
        var parameters = RelightingParameters(
            lights: [RelightLight(
                id: lightID,
                normalizedPosition: SIMD2(0.5, 0.5),
                direction: SIMD3(0, 0, 1),
                distanceMeters: 2,
                radius: 0.4,
                falloffSoftness: 0.72,
                color: SIMD3(repeating: 1),
                intensity: 1
            )],
            ambientIntensity: 0.58,
            diffuseStrength: 0.52,
            specularStrength: 0.02,
            specularShininess: 64
        )
        let saved = RelightingEditState(
            ambientIntensity: 0.25,
            diffuseStrength: 0.8,
            specularStrength: 0.12,
            specularShininess: 96,
            lightFalloffs: [LightFalloffEdit(lightID: lightID, softness: 0.31)]
        )

        saved.apply(to: &parameters)

        #expect(parameters.ambientIntensity == 0.25)
        #expect(parameters.diffuseStrength == 0.8)
        #expect(parameters.specularStrength == 0.12)
        #expect(parameters.specularShininess == 96)
        #expect(parameters.lights[0].falloffSoftness == 0.31)
    }

    @Test @MainActor func planningDraftIsNotPublishedUntilCaptureIsCommitted() async throws {
        let repository = InMemoryProjectRepository()
        let store = AppSessionStore(repository: repository)
        store.beginDraftProject()
        let draft = try #require(store.currentProject)

        #expect(store.projects.isEmpty)
        #expect(try await repository.loadProjects().isEmpty)

        let shot = Shot(
            projectID: draft.id,
            imageFileName: "photo.jpg",
            timestamp: Date(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(x: 0, y: 0, z: -2),
            lights: []
        )
        try await store.commitCurrentDraft(named: "Portrait A", shot: shot)

        #expect(store.projects.count == 1)
        #expect(store.projects.first?.name == "Portrait A")
        #expect(try await repository.loadProjects().count == 1)
    }

    @Test @MainActor func reopeningAProjectMaterializesItsLatestShotForEditor() async throws {
        let repository = InMemoryProjectRepository()
        let imageData = try makeImageData(width: 640, height: 480)
        var project = LightingProject(name: "Saved set")
        let shotID = UUID()
        let fileName = try await repository.saveImageData(imageData, shotID: shotID)
        let oldShot = Shot(
            projectID: project.id,
            imageFileName: fileName,
            timestamp: Date(timeIntervalSince1970: 10),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(x: 0, y: 0, z: -2),
            lights: []
        )
        var latestShot = Shot(
            id: shotID,
            projectID: project.id,
            imageFileName: fileName,
            timestamp: Date(timeIntervalSince1970: 20),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(x: 0, y: 0, z: -3),
            lights: []
        )
        let cachedNormals = NormalBuffer(
            width: 2,
            height: 1,
            normals: [SIMD3(0, 0, 1), simd_normalize(SIMD3(1, 1, 1))]
        )
        let cachedMask = ForegroundMaskBuffer(width: 2, height: 1, coverage: [0, 255])
        latestShot.normalCacheFileName = try await repository.saveAnalysisData(
            AnalysisCacheCodec.encode(cachedNormals),
            shotID: shotID,
            kind: .normals
        )
        latestShot.maskCacheFileName = try await repository.saveAnalysisData(
            AnalysisCacheCodec.encode(cachedMask),
            shotID: shotID,
            kind: .foregroundMask
        )
        project.shots = [oldShot, latestShot]
        try await repository.save(project)
        let store = AppSessionStore(repository: repository)
        await store.load()

        let openedShotID = try await store.prepareEditor(projectID: project.id)

        #expect(openedShotID == latestShot.id)
        #expect(store.editorPayload?.shotID == latestShot.id)
        #expect(store.editorPayload?.plan.subjectPosition == latestShot.subjectPosition)
        #expect(store.editorPayload?.cachedAnalysis?.normals.width == 2)
        #expect(store.editorPayload?.cachedAnalysis?.mask?.coverage == [0, 255])
    }

    @Test func analysisCacheRoundTripIsCompactAndPreservesValues() throws {
        let expectedNormals = [
            SIMD3<Float>(0, 0, 1),
            simd_normalize(SIMD3<Float>(0.25, -0.5, 1)),
            SIMD3<Float>.zero,
            simd_normalize(SIMD3<Float>(-1, 0.1, 0.4))
        ]
        let normalBuffer = NormalBuffer(width: 2, height: 2, normals: expectedNormals)
        let maskBuffer = ForegroundMaskBuffer(
            width: 2,
            height: 2,
            coverage: [0, 64, 192, 255]
        )

        let normalData = try AnalysisCacheCodec.encode(normalBuffer)
        let maskData = try AnalysisCacheCodec.encode(maskBuffer)
        let decodedNormals = try AnalysisCacheCodec.decodeNormals(normalData)
        let decodedMask = try AnalysisCacheCodec.decodeMask(maskData)

        #expect(normalData.count == 12 + 4 * 6)
        #expect(maskData.count == 12 + 4)
        #expect(decodedNormals.width == 2 && decodedNormals.height == 2)
        #expect(decodedMask.coverage == maskBuffer.coverage)
        for index in expectedNormals.indices {
            #expect(simd_distance(decodedNormals.normals[index], expectedNormals[index]) < 0.002)
        }
    }

    private func fixture(name: String, position: SIMD3<Float>, target: SIMD3<Float>) -> VirtualLight {
        let direction = SpatialMath.direction(from: position, to: target)!
        return VirtualLight(
            name: name,
            position: SpatialVector(position),
            orientation: SpatialQuaternion(SpatialMath.orientation(facing: direction)!),
            targetPosition: SpatialVector(target),
            height: position.y
        )
    }

    private func makeImageData(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ResultRenderingError.imageCreationFailed }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ResultRenderingError.imageCreationFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw ResultRenderingError.imageCreationFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResultRenderingError.imageCreationFailed }
        return data as Data
    }
}

private actor InMemoryProjectRepository: ProjectRepositoryProtocol {
    private var projects: [LightingProject] = []
    private var images: [String: Data] = [:]
    private var analysis: [String: Data] = [:]

    func loadProjects() async throws -> [LightingProject] { projects }

    func save(_ project: LightingProject) async throws {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
    }

    func saveImageData(_ data: Data, shotID: UUID) async throws -> String {
        let name = "shot-\(shotID.uuidString).jpg"
        images[name] = data
        return name
    }

    func imageData(fileName: String) async throws -> Data {
        guard let data = images[fileName] else { throw ProjectSessionError.missingCapturedPhoto }
        return data
    }

    func saveAnalysisData(
        _ data: Data,
        shotID: UUID,
        kind: AnalysisCacheKind
    ) async throws -> String {
        let name = "shot-\(shotID.uuidString)-\(kind.rawValue).bin"
        analysis[name] = data
        return name
    }

    func analysisData(fileName: String) async throws -> Data {
        guard let data = analysis[fileName] else { throw ProjectSessionError.missingCapturedPhoto }
        return data
    }
}
