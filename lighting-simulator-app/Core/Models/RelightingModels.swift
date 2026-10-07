import Foundation
import simd

/// GPU-only projection of a fixed world-space lamp. It is deliberately not persisted.
nonisolated struct RelightLight: Sendable, Equatable, Identifiable {
    let id: UUID
    var normalizedSourcePosition: SIMD2<Float> = SIMD2(0.5, 0.5)
    /// True only when the physical COB head is in front of the captured camera
    /// plane and therefore has a valid perspective origin in the photograph.
    /// A fixture behind the camera still lights the subject, but must not emit
    /// a fake screen-space cone from a clamped editor icon.
    var sourceIsProjectable: Bool = true
    var normalizedPosition: SIMD2<Float>
    var direction: SIMD3<Float>
    /// Fixed subject-to-fixture vector in the final displayed camera axes.
    /// Unlike `direction`, this does not move when the editor aim is dragged.
    var subjectToLightMeters: SIMD3<Float>? = nil
    /// Physical width represented by one aspect-corrected image unit on the
    /// plane passing through the aimed point. This lets the GPU construct a
    /// point-to-light vector for every pixel instead of assuming a frontal ray.
    var surfaceMetersPerShortEdge: Float = 1
    var distanceMeters: Float
    var radius: Float
    var falloffSoftness: Float
    var color: SIMD3<Float>
    var intensity: Float
}

nonisolated struct RelightingParameters: Sendable, Equatable {
    var lights: [RelightLight]
    var ambientIntensity: Float
    var diffuseStrength: Float
    var specularStrength: Float
    var specularShininess: Float
    var hazeIntensity: Float

    static let empty = RelightingParameters(
        lights: [], ambientIntensity: 0.58, diffuseStrength: 0.52,
        specularStrength: 0.02, specularShininess: 64, hazeIntensity: 0.15
    )
}

/// The only bridge between AR/world planning and image-space Metal rendering.
nonisolated enum SpatialToImageLightingMapper {
    static func makeParameters(from snapshot: SpatialPlanSnapshot) -> RelightingParameters {
        let camera = snapshot.cameraTransform.matrix
        let inverseCamera = camera.inverse

        let lights = snapshot.lights.prefix(LightingProject.maximumLightCount).map { light in
            let lightCamera = transform(light.position.simd, by: inverseCamera)
            let subjectCamera = transform(snapshot.subjectPosition.simd, by: inverseCamera)
            let sourceIsProjectable = lightCamera.z < -0.05
            let aimedWorld = SpatialMath.aimedPoint(for: light) ?? snapshot.subjectPosition.simd
            let aimedCamera = transform(aimedWorld, by: inverseCamera)
            let surfaceToLight = lightCamera - aimedCamera
            let distance = max(simd_length(surfaceToLight), 0.05)
            // Sapiens runs on the orientation-normalized photo. Rotate the AR
            // camera-space vector into that displayed pixel space as well;
            // otherwise landscape captures shade from the wrong screen axis.
            let direction = simd_length_squared(surfaceToLight) > 1e-6
                ? displayedDirection(
                    simd_normalize(surfaceToLight),
                    orientation: snapshot.cameraCalibration?.imageOrientation ?? .up
                )
                : SIMD3<Float>(0, 0, 1)
            let subjectToLight = displayedVector(
                lightCamera - subjectCamera,
                orientation: snapshot.cameraCalibration?.imageOrientation ?? .up
            )
            let projection = project(
                aimedCamera,
                calibration: snapshot.cameraCalibration,
                fallback: SIMD2<Float>(0.5, 0.5),
                clampRange: 0...1
            )
            let sourceProjection = project(
                projectableSource(
                    physicalSource: lightCamera,
                    target: aimedCamera
                ),
                calibration: snapshot.cameraCalibration,
                fallback: projection,
                clampRange: -2...3
            )
            let beamRadius = SpatialMath.beamRadius(
                distance: distance,
                beamAngleDegrees: light.beamAngle
            )
            let imageRadius = projectedRadius(
                beamRadius,
                at: aimedCamera,
                calibration: snapshot.cameraCalibration,
                fallbackDistance: distance
            )
            return RelightLight(
                id: light.id,
                normalizedSourcePosition: sourceProjection,
                sourceIsProjectable: sourceIsProjectable,
                normalizedPosition: projection,
                direction: direction,
                subjectToLightMeters: subjectToLight,
                surfaceMetersPerShortEdge: beamRadius / max(imageRadius, 0.001),
                distanceMeters: distance,
                radius: imageRadius,
                falloffSoftness: 0.72,
                color: emitterColor(for: light),
                intensity: light.enabled ? light.intensity / 100 * 2.2 : 0
            )
        }
        return RelightingParameters(
            lights: lights,
            ambientIntensity: 0.58,
            diffuseStrength: 0.52,
            specularStrength: 0.02,
            specularShininess: 64,
            hazeIntensity: 0.15
        )
    }

    private static func emitterColor(for light: VirtualLight) -> SIMD3<Float> {
        switch light.effectiveCOBType {
        case .classic:
            SpatialMath.kelvinToLinearRGB(light.kelvin)
        case .rgb:
            SpatialMath.sRGBToLinearRGB(light.effectiveRGBColor.simd)
        }
    }

    private static func transform(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let output = matrix * SIMD4<Float>(point, 1)
        return SIMD3(output.x, output.y, output.z)
    }

    /// Camera X/Y use right/up. The normal model uses the final displayed
    /// image's right/up axes, so rotate vector components exactly like the
    /// EXIF-normalized pixels while leaving camera-facing Z unchanged.
    private static func displayedDirection(
        _ value: SIMD3<Float>,
        orientation: CapturedImageOrientation
    ) -> SIMD3<Float> {
        simd_normalize(displayedVector(value, orientation: orientation))
    }

    private static func displayedVector(
        _ value: SIMD3<Float>,
        orientation: CapturedImageOrientation
    ) -> SIMD3<Float> {
        switch orientation {
        case .up: SIMD3(value.x, value.y, value.z)
        case .upMirrored: SIMD3(-value.x, value.y, value.z)
        case .down: SIMD3(-value.x, -value.y, value.z)
        case .downMirrored: SIMD3(value.x, -value.y, value.z)
        case .right: SIMD3(value.y, -value.x, value.z)
        case .rightMirrored: SIMD3(value.y, value.x, value.z)
        case .left: SIMD3(-value.y, value.x, value.z)
        case .leftMirrored: SIMD3(-value.y, -value.x, value.z)
        }
    }

    private static func project(
        _ point: SIMD3<Float>,
        calibration: CameraCalibration?,
        fallback: SIMD2<Float>,
        clampRange: ClosedRange<Float>
    ) -> SIMD2<Float> {
        // AR camera looks down -Z. Use captured intrinsics whenever possible;
        // the approximate FOV remains only for legacy shots without calibration.
        guard point.z < -0.01 else { return fallback }
        let projected: SIMD2<Float>
        if let calibration,
           calibration.sensorWidth > 0, calibration.sensorHeight > 0,
           calibration.fx > 0, calibration.fy > 0 {
            let depth = -point.z
            let sensor = SIMD2(
                (calibration.fx * point.x / depth + calibration.cx) / calibration.sensorWidth,
                (calibration.cy - calibration.fy * point.y / depth) / calibration.sensorHeight
            )
            projected = calibration.imageOrientation.orient(normalized: sensor)
        } else {
            let scale: Float = 0.866
            projected = SIMD2(
                0.5 + point.x / (-point.z) * scale,
                0.5 - point.y / (-point.z) * scale
            )
        }
        return simd_clamp(
            projected,
            SIMD2(repeating: clampRange.lowerBound),
            SIMD2(repeating: clampRange.upperBound)
        )
    }

    private static func projectedRadius(
        _ worldRadius: Float,
        at cameraPoint: SIMD3<Float>,
        calibration: CameraCalibration?,
        fallbackDistance: Float
    ) -> Float {
        guard let calibration, cameraPoint.z < -0.01 else {
            return min(max(worldRadius / max(fallbackDistance, 0.1), 0.08), 1.25)
        }
        let focal = (calibration.fx + calibration.fy) * 0.5
        let pixels = focal * worldRadius / max(-cameraPoint.z, 0.05)
        let shortEdge = max(min(calibration.orientedWidth, calibration.orientedHeight), 1)
        return min(max(pixels / shortEdge, 0.04), 2)
    }

    /// A real fixture may sit beside or behind the camera. Its projection then
    /// does not exist on the image plane, but its beam still enters the frame.
    /// Intersect the source→target segment with a near plane so the editor can
    /// draw the ray from the correct image edge instead of collapsing it.
    private static func projectableSource(
        physicalSource: SIMD3<Float>,
        target: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard physicalSource.z >= -0.05 else { return physicalSource }
        let delta = physicalSource - target
        guard delta.z > 0.001 else { return target }
        let amount = min(max((-0.05 - target.z) / delta.z, 0), 1)
        return target + delta * amount
    }
}
