import Foundation
import simd

/// Builds the editor's initial three-light plan from the subject placement.
/// The offsets live on the floor plane and are camera-relative, so "left",
/// "right", and "behind" keep their photographic meaning without retaining AR.
nonisolated enum InitialLightingPlanFactory {
  static let floorOffsetMeters: Float = 2
  static let fixtureHeightMeters: Float = 1.8

  static func makeLights(
    subjectBase: SIMD3<Float>,
    cameraTransform: simd_float4x4
  ) -> [VirtualLight] {
    let camera = cameraTransform.translation
    let opticalForward = planarUnit(SIMD2(
      -cameraTransform.columns.2.x,
      -cameraTransform.columns.2.z
    ), fallback: SIMD2(0, -1))
    let subjectToCamera = planarUnit(
      SIMD2(camera.x - subjectBase.x, camera.z - subjectBase.z),
      fallback: -opticalForward
    )
    let cameraRight = SIMD2(subjectToCamera.y, -subjectToCamera.x)
    let behindSubject = -subjectToCamera
    let target = subjectBase + SIMD3(0, SpatialMath.defaultSubjectAimHeight, 0)

    return [
      makeLight(
        name: "Key Light",
        floorDirection: -cameraRight,
        subjectBase: subjectBase,
        target: target
      ),
      makeLight(
        name: "Fill Light",
        floorDirection: cameraRight,
        subjectBase: subjectBase,
        target: target
      ),
      makeLight(
        name: "Rim Light",
        floorDirection: behindSubject,
        subjectBase: subjectBase,
        target: target
      ),
    ]
  }

  private static func makeLight(
    name: String,
    floorDirection: SIMD2<Float>,
    subjectBase: SIMD3<Float>,
    target: SIMD3<Float>
  ) -> VirtualLight {
    let floorOffset = floorDirection * floorOffsetMeters
    let position = subjectBase + SIMD3(
      floorOffset.x,
      fixtureHeightMeters,
      floorOffset.y
    )
    let orientation = SpatialMath.direction(from: position, to: target)
      .flatMap(SpatialMath.orientation(facing:)) ?? simd_quatf()
    return VirtualLight(
      name: name,
      position: SpatialVector(position),
      orientation: SpatialQuaternion(orientation),
      targetPosition: SpatialVector(target),
      height: fixtureHeightMeters
    )
  }

  private static func planarUnit(
    _ value: SIMD2<Float>,
    fallback: SIMD2<Float>
  ) -> SIMD2<Float> {
    let length = simd_length(value)
    guard length.isFinite, length > 0.0001 else {
      let fallbackLength = simd_length(fallback)
      return fallbackLength > 0.0001 ? fallback / fallbackLength : SIMD2(0, 1)
    }
    return value / length
  }
}
