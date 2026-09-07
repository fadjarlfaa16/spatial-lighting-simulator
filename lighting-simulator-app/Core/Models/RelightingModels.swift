import Foundation
import simd

/// GPU-only projection of a fixed world-space lamp. It is deliberately not persisted.
nonisolated struct RelightLight: Sendable, Equatable, Identifiable {
    let id: UUID
    var normalizedSourcePosition: SIMD2<Float> = SIMD2(0.5, 0.5)
    var normalizedPosition: SIMD2<Float>
    var direction: SIMD3<Float>
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

    static let empty = RelightingParameters(
        lights: [], ambientIntensity: 0.58, diffuseStrength: 0.52,
        specularStrength: 0.02, specularShininess: 64
    )
}

/// The only bridge between AR/world planning and image-space Metal rendering.
nonisolated enum SpatialToImageLightingMapper {
    static func makeParameters(from snapshot: SpatialPlanSnapshot) -> RelightingParameters {
        let camera = snapshot.cameraTransform.matrix
        let inverseCamera = camera.inverse

        let lights = snapshot.lights.prefix(LightingProject.maximumLightCount).map { light in
            let lightCamera = transform(light.position.simd, by: inverseCamera)
            let aimedWorld = SpatialMath.aimedPoint(for: light) ?? snapshot.subjectPosition.simd
            let aimedCamera = transform(aimedWorld, by: inverseCamera)
            let surfaceToLight = lightCamera - aimedCamera
            let distance = max(simd_length(surfaceToLight), 0.05)
            // Sapiens normals are displayed with +Z facing the camera and image Y
            // pointing down, hence the Y flip but no Z flip here.
            let direction = simd_length_squared(surfaceToLight) > 1e-6
                ? simd_normalize(SIMD3(surfaceToLight.x, -surfaceToLight.y, surfaceToLight.z))
                : SIMD3<Float>(0, 0, 1)
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
            return RelightLight(
                id: light.id,
                normalizedSourcePosition: sourceProjection,
                normalizedPosition: projection,
                direction: direction,
                distanceMeters: distance,
                radius: projectedRadius(
                    beamRadius,
                    at: aimedCamera,
                    calibration: snapshot.cameraCalibration,
                    fallbackDistance: distance
                ),
                falloffSoftness: 0.72,
                color: SpatialMath.kelvinToLinearRGB(light.kelvin),
                intensity: light.enabled ? light.intensity / 100 * 2.2 : 0
            )
        }
        return RelightingParameters(
            lights: lights,
            ambientIntensity: 0.58,
            diffuseStrength: 0.52,
            specularStrength: 0.02,
            specularShininess: 64
        )
    }

    private static func transform(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let output = matrix * SIMD4<Float>(point, 1)
        return SIMD3(output.x, output.y, output.z)
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
