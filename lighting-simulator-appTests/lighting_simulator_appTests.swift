import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import simd
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import lighting_simulator_app

struct LightingSimulatorTests {
    @Test func videoLandscapeOrientationMatchesPhotoCaptureConvention() {
        #expect(LandscapeVideoOrientation.rotationAngle(
            for: .landscapeLeft,
            cameraPosition: .front
        ) == 270)
        #expect(LandscapeVideoOrientation.rotationAngle(
            for: .landscapeRight,
            cameraPosition: .front
        ) == 90)
        #expect(LandscapeVideoOrientation.rotationAngle(
            for: .landscapeRight,
            cameraPosition: .back
        ) == 0)
        #expect(LandscapeVideoOrientation.rotationAngle(
            for: .landscapeLeft,
            cameraPosition: .back
        ) == 180)
    }

    @Test func initialLightingPlanUsesCameraRelativeTwoMeterFloorOffsets() throws {
        let camera = matrix_identity_float4x4
        let subject = SIMD3<Float>(0, 0, -3)
        let lights = InitialLightingPlanFactory.makeLights(
            subjectBase: subject,
            cameraTransform: camera
        )

        #expect(lights.map(\.name) == ["Key Light", "Fill Light", "Rim Light"])
        #expect(lights.count == 3)
        #expect(simd_distance(lights[0].position.simd, SIMD3(-2, 1.8, -3)) < 0.0001)
        #expect(simd_distance(lights[1].position.simd, SIMD3(2, 1.8, -3)) < 0.0001)
        #expect(simd_distance(lights[2].position.simd, SIMD3(0, 1.8, -5)) < 0.0001)

        for light in lights {
            #expect(abs(SpatialMath.horizontalDistance(light.position.simd, subject) - 2) < 0.0001)
            #expect(light.effectiveCOBType == .classic)
            #expect(light.isTargetLocked)
            #expect(try #require(SpatialMath.angularErrorDegrees(light: light)) < 0.001)
        }
    }

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

    @Test func rendererMappingKeepsTheFixtureFixedWhenAimMoves() throws {
        let subject = SIMD3<Float>(0, 1, -3)
        var light = fixture(name: "Key", position: SIMD3(-1, 2, -1), target: subject)
        let originalPlan = SpatialPlanSnapshot(
            projectID: UUID(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(subject),
            lights: [light]
        )
        let movedTarget = subject + SIMD3<Float>(0.6, 0.4, 0)
        light.targetPosition = SpatialVector(movedTarget)
        light.orientation = SpatialQuaternion(try #require(
            SpatialMath.orientation(facing: movedTarget - light.position.simd)
        ))
        let aimedPlan = SpatialPlanSnapshot(
            projectID: originalPlan.projectID,
            cameraTransform: originalPlan.cameraTransform,
            subjectPosition: originalPlan.subjectPosition,
            lights: [light]
        )

        let before = try #require(
            SpatialToImageLightingMapper.makeParameters(from: originalPlan)
                .lights.first?.subjectToLightMeters
        )
        let after = try #require(
            SpatialToImageLightingMapper.makeParameters(from: aimedPlan)
                .lights.first?.subjectToLightMeters
        )

        #expect(simd_distance(before, after) < 0.0001)
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
        #expect(mapped.surfaceMetersPerShortEdge > 0)
    }

    @Test func mapperDoesNotProjectAFixtureBehindTheCaptureCamera() {
        let subject = SIMD3<Float>(0, 1, -3)
        let behindCamera = fixture(
            name: "Behind camera",
            position: SIMD3(0, 1.5, 0.8),
            target: subject
        )
        let visibleSource = fixture(
            name: "Visible source",
            position: SIMD3(-1, 1.5, -1),
            target: subject
        )
        let snapshot = SpatialPlanSnapshot(
            projectID: UUID(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(subject),
            lights: [behindCamera, visibleSource]
        )

        let mapped = SpatialToImageLightingMapper.makeParameters(from: snapshot).lights

        #expect(mapped[0].sourceIsProjectable == false)
        #expect(mapped[1].sourceIsProjectable == true)
    }

    @Test func mapperPreservesSideLightingInDisplayedPhotoSpace() {
        let target = SIMD3<Float>(0, 1, -3)
        let leftLight = fixture(name: "Left", position: SIMD3(-2, 1, -3), target: target)
        let upSnapshot = SpatialPlanSnapshot(
            projectID: UUID(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            cameraCalibration: CameraCalibration(
                fx: 1_000, fy: 1_000, cx: 960, cy: 720,
                sensorWidth: 1_920, sensorHeight: 1_440,
                imageOrientation: .up
            ),
            subjectPosition: SpatialVector(target),
            lights: [leftLight]
        )
        let rightSnapshot = SpatialPlanSnapshot(
            projectID: upSnapshot.projectID,
            cameraTransform: upSnapshot.cameraTransform,
            cameraCalibration: CameraCalibration(
                fx: 1_000, fy: 1_000, cx: 960, cy: 720,
                sensorWidth: 1_920, sensorHeight: 1_440,
                imageOrientation: .right
            ),
            subjectPosition: upSnapshot.subjectPosition,
            lights: [leftLight]
        )

        let up = SpatialToImageLightingMapper.makeParameters(from: upSnapshot).lights[0].direction
        let right = SpatialToImageLightingMapper.makeParameters(from: rightSnapshot).lights[0].direction

        #expect(up.x < -0.99)
        #expect(abs(up.y) < 0.001)
        #expect(abs(right.x) < 0.001)
        #expect(right.y > 0.99)
    }

    @Test @MainActor func metalShaderDarkensTheSurfaceFacingAwayFromASideLight() async throws {
        let data = try makeImageData(width: 32, height: 8)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let normals = (0..<256).map { index in
            index % 32 < 16 ? SIMD3<Float>(-1, 0, 0) : SIMD3<Float>(1, 0, 0)
        }
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(width: 32, height: 8, normals: normals)
        )
        let parameters = RelightingParameters(
            lights: [RelightLight(
                id: UUID(),
                normalizedPosition: SIMD2(0.5, 0.5),
                direction: SIMD3(-1, 0, 0),
                surfaceMetersPerShortEdge: 1,
                distanceMeters: 2,
                radius: 2,
                falloffSoftness: 0.7,
                color: SIMD3(repeating: 1),
                intensity: 1
            )],
            ambientIntensity: 0.05,
            diffuseStrength: 1,
            specularStrength: 0,
            specularShininess: 64,
            hazeIntensity: 0
        )

        let output = try await resources.export(parameters: parameters)
        let halves = try meanBrightnessByHalf(output)

        #expect(halves.left > halves.right * 2)
    }

    @Test @MainActor func segmentationConfinesNormalShadingToTheSubject() async throws {
        let width = 64
        let height = 32
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (27...36).contains(x) && (12...19).contains(y) ? 255 : 0
            }
        )
        let towardLight = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(-1, 0, 0), count: width * height)
            ),
            mask: mask
        )
        let awayFromLight = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(1, 0, 0), count: width * height)
            ),
            mask: mask
        )
        let parameters = RelightingParameters(
            lights: [RelightLight(
                id: UUID(),
                normalizedPosition: SIMD2(0.5, 0.5),
                direction: SIMD3(-1, 0, 0),
                surfaceMetersPerShortEdge: 1,
                distanceMeters: 1,
                radius: 2,
                falloffSoftness: 0.7,
                color: SIMD3(repeating: 1),
                intensity: 1
            )],
            ambientIntensity: 0.05,
            diffuseStrength: 1,
            specularStrength: 0,
            specularShininess: 64,
            hazeIntensity: 0
        )

        let lit = try await towardLight.export(parameters: parameters)
        let shaded = try await awayFromLight.export(parameters: parameters)
        let subject = SIMD2<Float>(0.5, 0.5)
        let background = SIMD2<Float>(0.78, 0.5)
        let litSubject = try brightness(of: lit, at: subject)
        let shadedSubject = try brightness(of: shaded, at: subject)
        let litBackground = try brightness(of: lit, at: background)
        let shadedBackground = try brightness(of: shaded, at: background)

        #expect(litSubject > shadedSubject * 2)
        #expect(abs(litBackground - shadedBackground) <= 2)
    }

    @Test @MainActor func projectedShadowMovesAndStretchesAwayFromAFrontLight() async throws {
        let width = 96
        let height = 48
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let normals = NormalBuffer(
            width: width,
            height: height,
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
        )
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (42...53).contains(x) && (17...30).contains(y) ? 255 : 0
            }
        )
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: normals,
            mask: mask
        )

        func parameters(distance: Float) -> RelightingParameters {
            RelightingParameters(
                lights: [RelightLight(
                    id: UUID(),
                    normalizedSourcePosition: SIMD2(0.15, 0.5),
                    normalizedPosition: SIMD2(0.5, 0.5),
                    direction: simd_normalize(SIMD3(-0.5, 0, 0.86)),
                    surfaceMetersPerShortEdge: 1,
                    distanceMeters: distance,
                    radius: 2,
                    falloffSoftness: 0.5,
                    color: SIMD3(repeating: 1),
                    intensity: 1
                )],
                ambientIntensity: 0.05,
                diffuseStrength: 1,
                specularStrength: 0,
                specularShininess: 64,
                hazeIntensity: 0
            )
        }

        let close = try await resources.export(parameters: parameters(distance: 1))
        let far = try await resources.export(parameters: parameters(distance: 4))
        // Equal-distance receivers on either side of the subject. A left/front
        // fixture casts only to the right; a nearby fixture also stretches far
        // enough to cover the outer receiver, unlike the distant fixture.
        let awayReceiver = SIMD2<Float>(0.72, 0.5)
        let sourceSideReceiver = SIMD2<Float>(0.28, 0.5)
        let closeAway = try brightness(of: close, at: awayReceiver)
        let closeSourceSide = try brightness(of: close, at: sourceSideReceiver)
        let farAway = try brightness(of: far, at: awayReceiver)
        let farSourceSide = try brightness(of: far, at: sourceSideReceiver)

        // Compare normalized contrast because physical inverse-square falloff
        // makes the close render globally brighter than the distant render.
        let closeShadowContrast = (closeSourceSide - closeAway)
            / max(closeSourceSide, 1)
        let farShadowContrast = (farSourceSide - farAway)
            / max(farSourceSide, 1)
        #expect(closeShadowContrast > farShadowContrast + 0.015)
        #expect(abs(farAway - farSourceSide) <= 5)
    }

    @Test @MainActor func opposingAimDirectionsCastOpposingShadows() async throws {
        let width = 128
        let height = 64
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (56...71).contains(x) && (22...41).contains(y) ? 255 : 0
            }
        )
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            ),
            mask: mask
        )
        func parameters(
            horizontalDirection: Float,
            verticalDirection: Float = 0
        ) -> RelightingParameters {
            RelightingParameters(
                lights: [RelightLight(
                    id: UUID(),
                    // Deliberately fixed: shadow travel must follow the measured
                    // 3-D ray, not this editor-icon projection.
                    normalizedSourcePosition: SIMD2(0.12, 0.5),
                    normalizedPosition: SIMD2(0.5, 0.5),
                    direction: simd_normalize(SIMD3(
                        horizontalDirection,
                        verticalDirection,
                        0.76
                    )),
                    surfaceMetersPerShortEdge: 1,
                    distanceMeters: 1.2,
                    radius: 2,
                    falloffSoftness: 0.55,
                    color: SIMD3(repeating: 1),
                    intensity: 1
                )],
                ambientIntensity: 0.04,
                diffuseStrength: 1,
                specularStrength: 0,
                specularShininess: 64,
                hazeIntensity: 0
            )
        }

        let sourceOnLeft = try await resources.export(
            parameters: parameters(horizontalDirection: -0.65)
        )
        let sourceOnRight = try await resources.export(
            parameters: parameters(horizontalDirection: 0.65)
        )
        let sourceAbove = try await resources.export(
            parameters: parameters(horizontalDirection: 0, verticalDirection: 0.65)
        )
        let sourceBelow = try await resources.export(
            parameters: parameters(horizontalDirection: 0, verticalDirection: -0.65)
        )
        let leftReceiver = SIMD2<Float>(0.28, 0.5)
        let rightReceiver = SIMD2<Float>(0.72, 0.5)
        let upperReceiver = SIMD2<Float>(0.5, 0.18)
        let lowerReceiver = SIMD2<Float>(0.5, 0.82)

        #expect(try brightness(of: sourceOnLeft, at: rightReceiver)
            < brightness(of: sourceOnLeft, at: leftReceiver) - 5)
        #expect(try brightness(of: sourceOnRight, at: leftReceiver)
            < brightness(of: sourceOnRight, at: rightReceiver) - 5)
        #expect(try brightness(of: sourceAbove, at: lowerReceiver)
            < brightness(of: sourceAbove, at: upperReceiver) - 5)
        #expect(try brightness(of: sourceBelow, at: upperReceiver)
            < brightness(of: sourceBelow, at: lowerReceiver) - 5)
    }

    @Test @MainActor func changingAimDoesNotDragAFixedFixtureShadow() async throws {
        let width = 128
        let height = 64
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (56...71).contains(x) && (22...41).contains(y) ? 255 : 0
            }
        )
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            ),
            mask: mask
        )
        let fixedSubjectToLight = SIMD3<Float>(-0.55, 0.30, 0.95)

        func parameters(aimedPoint: SIMD2<Float>) -> RelightingParameters {
            // The test image is 2:1, so an aspect-corrected image unit maps X
            // by two and displayed Y is the inverse of texture-UV Y.
            let targetOffset = SIMD3<Float>(
                (aimedPoint.x - 0.5) * 2,
                -(aimedPoint.y - 0.5),
                0
            )
            let targetToLight = fixedSubjectToLight - targetOffset
            let distance = simd_length(targetToLight)
            return RelightingParameters(
                lights: [RelightLight(
                    id: UUID(),
                    normalizedSourcePosition: SIMD2(0.1, 0.2),
                    sourceIsProjectable: false,
                    normalizedPosition: aimedPoint,
                    direction: targetToLight / distance,
                    subjectToLightMeters: fixedSubjectToLight,
                    surfaceMetersPerShortEdge: 1,
                    distanceMeters: distance,
                    radius: 10,
                    falloffSoftness: 0.55,
                    color: SIMD3(repeating: 1),
                    intensity: 1
                )],
                ambientIntensity: 0.04,
                diffuseStrength: 1,
                specularStrength: 0,
                specularShininess: 64,
                hazeIntensity: 0
            )
        }

        let aimedUpperLeft = try await resources.export(
            parameters: parameters(aimedPoint: SIMD2(0.36, 0.38))
        )
        let aimedLowerRight = try await resources.export(
            parameters: parameters(aimedPoint: SIMD2(0.64, 0.62))
        )
        let expectedShadow = SIMD2<Float>(0.72, 0.72)
        let sourceFacingSide = SIMD2<Float>(0.28, 0.28)

        #expect(try brightness(of: aimedUpperLeft, at: expectedShadow)
            < brightness(of: aimedUpperLeft, at: sourceFacingSide) - 5)
        #expect(try brightness(of: aimedLowerRight, at: expectedShadow)
            < brightness(of: aimedLowerRight, at: sourceFacingSide) - 5)
    }

    @Test @MainActor func projectedShadowFeatherCreatesAGradualPenumbra() async throws {
        let width = 256
        let height = 128
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (112...143).contains(x) && (44...83).contains(y) ? 255 : 0
            }
        )
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            ),
            mask: mask
        )
        func parameters(directionZ: Float) -> RelightingParameters {
            RelightingParameters(
                lights: [RelightLight(
                    id: UUID(),
                    normalizedSourcePosition: SIMD2(0.15, 0.5),
                    normalizedPosition: SIMD2(0.5, 0.5),
                    direction: simd_normalize(SIMD3(-0.5, 0, directionZ)),
                    surfaceMetersPerShortEdge: 1,
                    distanceMeters: 1,
                    radius: 2,
                    falloffSoftness: 1,
                    color: SIMD3(repeating: 1),
                    intensity: 1
                )],
                ambientIntensity: 0.05,
                diffuseStrength: 1,
                specularStrength: 0,
                specularShininess: 64,
                hazeIntensity: 0
            )
        }

        let shadowed = try await resources.export(parameters: parameters(directionZ: 0.86))
        let noCastShadow = try await resources.export(parameters: parameters(directionZ: -0.86))
        let corePoint = SIMD2<Float>(0.63, 0.5)
        let penumbraPoint = SIMD2<Float>(0.63, 0.70)
        let clearPoint = SIMD2<Float>(0.63, 0.95)
        let coreDrop = try brightness(of: noCastShadow, at: corePoint)
            - brightness(of: shadowed, at: corePoint)
        let penumbraDrop = try brightness(of: noCastShadow, at: penumbraPoint)
            - brightness(of: shadowed, at: penumbraPoint)
        let clearDrop = try brightness(of: noCastShadow, at: clearPoint)
            - brightness(of: shadowed, at: clearPoint)

        #expect(coreDrop > penumbraDrop + 3)
        #expect(penumbraDrop > clearDrop + 2)
    }

    @Test @MainActor func volumetricBeamFeathersAcrossItsFormerLongitudinalCutoff() async throws {
        let width = 256
        let height = 128
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            )
        )
        let output = try await resources.export(parameters: RelightingParameters(
            lights: [RelightLight(
                id: UUID(),
                normalizedSourcePosition: SIMD2(0.2, 0.5),
                normalizedPosition: SIMD2(0.5, 0.5),
                direction: SIMD3(0, 0, 1),
                surfaceMetersPerShortEdge: 1,
                distanceMeters: 2,
                radius: 0.3,
                falloffSoftness: 1,
                color: SIMD3(repeating: 1),
                intensity: 1
            )],
            ambientIntensity: 0,
            diffuseStrength: 0,
            specularStrength: 0,
            specularShininess: 64,
            hazeIntensity: 1
        ))

        // The old strict 1.5x shaft domain ended at x = 0.65 for this setup.
        // Both sides of that coordinate must now belong to one continuous fade.
        let beforeBoundary = try brightness(of: output, at: SIMD2(0.63, 0.5))
        let afterBoundary = try brightness(of: output, at: SIMD2(0.67, 0.5))
        let fullyOutside = try brightness(of: output, at: SIMD2(0.9, 0.5))

        #expect(abs(beforeBoundary - afterBoundary) < 35)
        #expect(afterBoundary > fullyOutside + 8)
    }

    @Test @MainActor func behindCameraFixtureDoesNotCreateAFakeScreenSpaceCone() async throws {
        let width = 128
        let height = 64
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            )
        )
        func parameters(sourceIsProjectable: Bool) -> RelightingParameters {
            RelightingParameters(
                lights: [RelightLight(
                    id: UUID(),
                    normalizedSourcePosition: SIMD2(0.1, 0.5),
                    sourceIsProjectable: sourceIsProjectable,
                    normalizedPosition: SIMD2(0.5, 0.5),
                    direction: SIMD3(0, 0, 1),
                    surfaceMetersPerShortEdge: 1,
                    distanceMeters: 2,
                    radius: 0.35,
                    falloffSoftness: 0.8,
                    color: SIMD3(repeating: 1),
                    intensity: 1
                )],
                ambientIntensity: 0,
                diffuseStrength: 0,
                specularStrength: 0,
                specularShininess: 64,
                hazeIntensity: 1
            )
        }

        let projectable = try await resources.export(
            parameters: parameters(sourceIsProjectable: true)
        )
        let behindCamera = try await resources.export(
            parameters: parameters(sourceIsProjectable: false)
        )
        let sample = SIMD2<Float>(0.5, 0.5)

        #expect(try brightness(of: projectable, at: sample) > 8)
        #expect(try brightness(of: behindCamera, at: sample) <= 3)
    }

    @Test @MainActor func rearLightCreatesARimOnlyAtTheFacingMaskEdge() async throws {
        let width = 96
        let height = 48
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (36...59).contains(x) && (16...34).contains(y) ? 255 : 0
            }
        )
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            ),
            mask: mask
        )
        let parameters = RelightingParameters(
            lights: [RelightLight(
                id: UUID(),
                normalizedSourcePosition: SIMD2(0.5, 0.1),
                normalizedPosition: SIMD2(0.5, 0.5),
                direction: simd_normalize(SIMD3(0, 0.4, -0.9)),
                surfaceMetersPerShortEdge: 1,
                distanceMeters: 1,
                radius: 2,
                falloffSoftness: 0.6,
                color: SIMD3(repeating: 1),
                intensity: 1
            )],
            ambientIntensity: 0.03,
            diffuseStrength: 1,
            specularStrength: 0,
            specularShininess: 64,
            hazeIntensity: 0
        )

        let output = try await resources.export(parameters: parameters)
        let facingEdge = try brightness(of: output, at: SIMD2(0.5, 0.35))
        let subjectCentre = try brightness(of: output, at: SIMD2(0.5, 0.52))

        // Rim is deliberately subtle: it should lift the facing silhouette
        // without turning into a thick synthetic outline.
        #expect(facingEdge > subjectCentre + 40)
    }

    @Test @MainActor func rearRimFollowsHorizontalAndVerticalLightDirection() async throws {
        let width = 128
        let height = 64
        let data = try makeImageData(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let mask = ForegroundMaskBuffer(
            width: width,
            height: height,
            coverage: (0..<(width * height)).map { index in
                let x = index % width
                let y = index / width
                return (48...79).contains(x) && (18...45).contains(y) ? 255 : 0
            }
        )
        let resources = try MetalRelightingResources(
            originalImage: image,
            normals: NormalBuffer(
                width: width,
                height: height,
                normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: width * height)
            ),
            mask: mask
        )
        func parameters(direction: SIMD3<Float>) -> RelightingParameters {
            RelightingParameters(
                lights: [RelightLight(
                    id: UUID(),
                    normalizedSourcePosition: SIMD2(0.9, 0.9),
                    normalizedPosition: SIMD2(0.5, 0.5),
                    direction: simd_normalize(direction),
                    surfaceMetersPerShortEdge: 1,
                    distanceMeters: 1,
                    radius: 2,
                    falloffSoftness: 0.7,
                    color: SIMD3(repeating: 1),
                    intensity: 1
                )],
                ambientIntensity: 0.02,
                diffuseStrength: 1,
                specularStrength: 0,
                specularShininess: 64,
                hazeIntensity: 0
            )
        }

        let fromLeft = try await resources.export(
            parameters: parameters(direction: SIMD3(-0.55, 0, -0.84))
        )
        let fromAbove = try await resources.export(
            parameters: parameters(direction: SIMD3(0, 0.55, -0.84))
        )

        #expect(try brightness(of: fromLeft, at: SIMD2(0.38, 0.5))
            > brightness(of: fromLeft, at: SIMD2(0.62, 0.5)) + 8)
        #expect(try brightness(of: fromAbove, at: SIMD2(0.5, 0.29))
            > brightness(of: fromAbove, at: SIMD2(0.5, 0.71)) + 8)
        #expect(try brightness(of: fromAbove, at: SIMD2(0.5, 0.265))
            > brightness(of: fromAbove, at: SIMD2(0.5, 0.12)) + 3)
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

    @Test func editorPlanarMoveUsesCameraRelativeTenCentimeterSteps() {
        let camera = matrix_identity_float4x4
        let subject = SIMD3<Float>(0, 0, 0)
        let start = SIMD3<Float>(1, 1.8, 1)
        let forward = SpatialMath.movedLightPosition(
            start,
            relativeTo: subject,
            cameraTransform: camera,
            direction: .forward
        )
        let backward = SpatialMath.movedLightPosition(
            start,
            relativeTo: subject,
            cameraTransform: camera,
            direction: .backward
        )
        let left = SpatialMath.movedLightPosition(
            start,
            relativeTo: subject,
            cameraTransform: camera,
            direction: .left
        )
        let right = SpatialMath.movedLightPosition(
            start,
            relativeTo: subject,
            cameraTransform: camera,
            direction: .right
        )

        #expect(abs(forward.z - 0.9) < 0.0001)
        #expect(abs(backward.z - 1.1) < 0.0001)
        #expect(abs(left.x - 0.9) < 0.0001)
        #expect(abs(right.x - 1.1) < 0.0001)
        for moved in [forward, backward, left, right] {
            #expect(abs(SpatialMath.horizontalDistance(start, moved) - 0.1) < 0.0001)
            #expect(moved.y == start.y)
        }
    }

    @Test func editorPlanarMoveNeverExceedsSevenMetersFromSubject() {
        let subject = SIMD3<Float>.zero
        let start = SIMD3<Float>(6.98, 2.4, 0)
        let moved = SpatialMath.movedLightPosition(
            start,
            relativeTo: subject,
            cameraTransform: matrix_identity_float4x4,
            direction: .right
        )

        #expect(SpatialMath.horizontalDistance(moved, subject)
            <= SpatialMath.editorLightMaximumFloorDistance + 0.0001)
        #expect(moved.y == start.y)
    }

    @Test func masterPhotoAndEditorProxyUseIndependentDecodeSizes() throws {
        let input = try makeImageData(width: 4_000, height: 2_000)
        let proxy = try ImageOrientationNormalizer(maximumPixelDimension: 1_024)
            .normalize(data: input)
        let master = try ImageOrientationNormalizer(
            maximumPixelDimension: ImageOrientationNormalizer.exportMaximumPixelDimension
        )
            .normalize(data: input)

        #expect(proxy.width == 1_024)
        #expect(proxy.height == 512)
        #expect(master.width == 4_000)
        #expect(master.height == 2_000)
    }

    @Test func rgbCOBUsesPickedColorWithoutChangingSpatialMapping() {
        let target = SIMD3<Float>(0, 1, -3)
        var classic = fixture(name: "Key", position: SIMD3(-1, 2, -1), target: target)
        let projectID = UUID()
        let classicPlan = SpatialPlanSnapshot(
            projectID: projectID,
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(target),
            lights: [classic]
        )
        let classicMapped = SpatialToImageLightingMapper.makeParameters(from: classicPlan).lights[0]

        classic.setCOBType(.rgb)
        classic.setRGBColor(LightRGBColor(red: 0.5, green: 0.25, blue: 1))
        let rgbPlan = SpatialPlanSnapshot(
            projectID: projectID,
            cameraTransform: classicPlan.cameraTransform,
            subjectPosition: classicPlan.subjectPosition,
            lights: [classic]
        )
        let rgbMapped = SpatialToImageLightingMapper.makeParameters(from: rgbPlan).lights[0]
        let expected = SpatialMath.sRGBToLinearRGB(SIMD3(0.5, 0.25, 1))

        #expect(simd_distance(rgbMapped.color, expected) < 0.0001)
        #expect(rgbMapped.normalizedPosition == classicMapped.normalizedPosition)
        #expect(rgbMapped.direction == classicMapped.direction)
        #expect(rgbMapped.distanceMeters == classicMapped.distanceMeters)
        #expect(rgbMapped.radius == classicMapped.radius)
    }

    @Test func legacyLightWithoutCOBFieldsDefaultsToClassic() throws {
        let light = fixture(
            name: "Legacy",
            position: SIMD3(1, 2, -1),
            target: SIMD3(0, 1, -3)
        )
        let encoded = try JSONEncoder().encode(light)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "cobType")
        object.removeValue(forKey: "selectedRGBColor")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(VirtualLight.self, from: legacyData)

        #expect(decoded.effectiveCOBType == .classic)
        #expect(decoded.effectiveRGBColor == .white)
    }

    @Test @MainActor func exportResourcesUseMasterImageResolution() async throws {
        let proxyData = try makeImageData(width: 64, height: 32)
        let masterData = try makeImageData(width: 128, height: 64)
        let proxy = try ImageOrientationNormalizer(maximumPixelDimension: 64)
            .normalize(data: proxyData)
        let master = try ImageOrientationNormalizer(maximumPixelDimension: 128)
            .normalize(data: masterData)
        let normals = NormalBuffer(
            width: 8,
            height: 4,
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 32)
        )
        let previewResources = try MetalRelightingResources(
            originalImage: proxy,
            normals: normals
        )
        let exportResources = try previewResources.replacingOriginalImage(master)

        let exported = try await exportResources.export(parameters: .empty)

        #expect(previewResources.width == 64)
        #expect(exported.width == 128)
        #expect(exported.height == 64)
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
            specularShininess: 64,
            hazeIntensity: 0.15
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

    @Test @MainActor func videoDraftPersistsItsMediaKindOnlyAfterStillReview() async throws {
        let repository = InMemoryProjectRepository()
        let store = AppSessionStore(repository: repository)
        store.beginDraftProject(mediaKind: .video)
        let draft = try #require(store.currentProject)

        #expect(draft.effectiveMediaKind == .video)
        #expect(store.projects.isEmpty)

        let shot = Shot(
            projectID: draft.id,
            imageFileName: "lighting-reference.jpg",
            timestamp: Date(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(x: 0, y: 0, z: -2),
            lights: []
        )
        try await store.commitCurrentDraft(named: "Video portrait", shot: shot)

        #expect(store.projects.first?.effectiveMediaKind == .video)
        #expect(try await repository.loadProjects().first?.effectiveMediaKind == .video)
    }

    @Test func legacyProjectWithoutMediaKindDefaultsToPhoto() throws {
        let project = LightingProject(name: "Existing project")
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "mediaKind")

        let decoded = try JSONDecoder().decode(
            LightingProject.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.effectiveMediaKind == .photo)
    }

    @Test func shotRoundTripsItsRelitVideoReference() throws {
        let shot = Shot(
            projectID: UUID(),
            imageFileName: "lighting-reference.jpg",
            sourceVideoFileName: "source.mov",
            videoFileName: "relit.mov",
            timestamp: Date(),
            cameraTransform: SpatialTransform(matrix_identity_float4x4),
            subjectPosition: SpatialVector(x: 0, y: 0, z: -2),
            lights: []
        )

        let decoded = try JSONDecoder().decode(Shot.self, from: JSONEncoder().encode(shot))
        #expect(decoded.sourceVideoFileName == "source.mov")
        #expect(decoded.videoFileName == "relit.mov")
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

    private func meanBrightnessByHalf(_ image: CGImage) throws -> (left: Float, right: Float) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let created = pixels.withUnsafeMutableBytes { storage in
            CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        }
        guard let context = created else { throw ResultRenderingError.imageCreationFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var left: Float = 0
        var right: Float = 0
        let half = image.width / 2
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let brightness = Float(pixels[offset])
                    + Float(pixels[offset + 1])
                    + Float(pixels[offset + 2])
                if x < half { left += brightness } else { right += brightness }
            }
        }
        let samples = Float(max(half * image.height, 1))
        return (left / samples, right / samples)
    }

    private func brightness(of image: CGImage, at point: SIMD2<Float>) throws -> Float {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = pixels.withUnsafeMutableBytes { storage in
            CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        }
        guard let context else { throw ResultRenderingError.imageCreationFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let x = min(max(Int(point.x * Float(image.width)), 0), image.width - 1)
        let y = min(max(Int(point.y * Float(image.height)), 0), image.height - 1)
        let offset = (y * image.width + x) * 4
        return Float(pixels[offset])
            + Float(pixels[offset + 1])
            + Float(pixels[offset + 2])
    }
}

private actor InMemoryProjectRepository: ProjectRepositoryProtocol {
    private var projects: [LightingProject] = []
    private var images: [String: Data] = [:]
    private var analysis: [String: Data] = [:]
    private var videos: [String: Data] = [:]

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

    func saveVideo(
        from sourceURL: URL,
        shotID: UUID,
        kind: ProjectVideoKind
    ) async throws -> String {
        let name = "shot-\(shotID.uuidString)-\(kind.rawValue).mov"
        videos[name] = try Data(contentsOf: sourceURL)
        return name
    }

    func videoURL(fileName: String) async throws -> URL {
        guard let data = videos[fileName] else { throw ProjectSessionError.missingCapturedPhoto }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
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
