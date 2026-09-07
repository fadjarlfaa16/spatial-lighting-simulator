import Foundation
import simd

nonisolated enum SpatialMath {
  static let defaultSubjectAimHeight: Float = 1.0

  static func direction(from origin: SIMD3<Float>, to target: SIMD3<Float>) -> SIMD3<Float>? {
    let delta = target - origin
    let magnitude = simd_length(delta)
    guard magnitude > .ulpOfOne else { return nil }
    return delta / magnitude
  }

  static func distance(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> Float {
    simd_distance(first, second)
  }

  static func horizontalDistance(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> Float {
    simd_distance(SIMD2(first.x, first.z), SIMD2(second.x, second.z))
  }

  /// Uses the optical axis at shutter time to choose a sensible vertical target
  /// over the planned X/Z subject position. This preserves the user's framing
  /// without pretending that a floor raycast measured the subject's height.
  static func captureFramingTarget(
    subjectBase: SIMD3<Float>,
    cameraTransform: simd_float4x4
  ) -> SIMD3<Float> {
    let camera = cameraTransform.translation
    let forward = -SIMD3(
      cameraTransform.columns.2.x,
      cameraTransform.columns.2.y,
      cameraTransform.columns.2.z
    )
    let horizontalForward = SIMD2(forward.x, forward.z)
    let horizontalDelta = SIMD2(subjectBase.x - camera.x, subjectBase.z - camera.z)
    let denominator = simd_length_squared(horizontalForward)
    guard denominator > 0.001 else {
      return subjectBase + SIMD3(0, defaultSubjectAimHeight, 0)
    }
    let travel = simd_dot(horizontalDelta, horizontalForward) / denominator
    let opticalY = camera.y + forward.y * travel
    let relativeY = min(max(opticalY - subjectBase.y, 0.25), 2.5)
    return subjectBase + SIMD3(0, relativeY, 0)
  }

  /// World-space axes corresponding to the final JPEG's screen-right and
  /// screen-down directions. They are derived from the shutter camera pose,
  /// then rotated to match the orientation baked into the captured pixels.
  static func capturedScreenAxes(
    cameraTransform: simd_float4x4,
    orientation: CapturedImageOrientation
  ) -> (right: SIMD3<Float>, down: SIMD3<Float>) {
    let cameraRight = simd_normalize(SIMD3(
      cameraTransform.columns.0.x,
      cameraTransform.columns.0.y,
      cameraTransform.columns.0.z
    ))
    let cameraUp = simd_normalize(SIMD3(
      cameraTransform.columns.1.x,
      cameraTransform.columns.1.y,
      cameraTransform.columns.1.z
    ))
    return switch orientation {
    case .up: (cameraRight, -cameraUp)
    case .down: (-cameraRight, cameraUp)
    case .right: (cameraUp, cameraRight)
    case .left: (-cameraUp, -cameraRight)
    }
  }

  /// Maps AR world X/Z to the drawing plane X/Y without creating a second coordinate system.
  static func topDown(_ worldPoint: SIMD3<Float>) -> SIMD2<Float> {
    SIMD2(worldPoint.x, worldPoint.z)
  }

  /// Converts correlated color temperature to display sRGB through CIE xy/XYZ.
  /// Brightness is deliberately normalized: CCT controls chromaticity, not fixture output.
  static func kelvinToRGB(_ temperature: Float) -> SIMD3<Float> {
    let linear = kelvinToLinearRGB(temperature)
    return SIMD3(
      linearToSRGB(linear.x),
      linearToSRGB(linear.y),
      linearToSRGB(linear.z)
    ).clamped(lower: 0, upper: 1)
  }

  /// Linear sRGB emitter color normalized to a peak channel of one.
  /// This is the representation used by the lighting equation and Metal shader.
  static func kelvinToLinearRGB(_ temperature: Float) -> SIMD3<Float> {
    let kelvin = Double(min(max(temperature, 1_667), 25_000))
    let x: Double
    if kelvin <= 4_000 {
      x =
        -0.2661239e9 / pow(kelvin, 3)
        - 0.2343589e6 / pow(kelvin, 2)
        + 0.8776956e3 / kelvin
        + 0.179910
    } else {
      x =
        -3.0258469e9 / pow(kelvin, 3)
        + 2.1070379e6 / pow(kelvin, 2)
        + 0.2226347e3 / kelvin
        + 0.240390
    }

    let y: Double
    if kelvin <= 2_222 {
      y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2) + 2.18555832 * x - 0.20219683
    } else if kelvin <= 4_000 {
      y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2) + 2.09137015 * x - 0.16748867
    } else {
      y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2) + 3.75112997 * x - 0.37001483
    }

    let xyz = SIMD3<Double>(x / y, 1, (1 - x - y) / y)
    var rgb = SIMD3<Double>(
      3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
      -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
      0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z
    )
    rgb = simd_max(rgb, SIMD3<Double>.zero)
    let peak = max(rgb.x, max(rgb.y, rgb.z))
    guard peak > .ulpOfOne else { return SIMD3(repeating: 1) }
    return SIMD3<Float>(rgb / peak)
  }

  static func beamRadius(distance: Float, beamAngleDegrees: Float) -> Float {
    let angle = min(max(beamAngleDegrees, 0), 179) * .pi / 180
    return max(distance, 0) * tan(angle / 2)
  }

  static func beamSolidAngle(beamAngleDegrees: Float) -> Float {
    let halfAngle = min(max(beamAngleDegrees, 1), 179) * .pi / 360
    return max(2 * .pi * (1 - cos(halfAngle)), 0.001)
  }

  /// Cosine-power exponent whose intensity is 50% at the nominal beam half-angle.
  static func cobDistributionExponent(beamAngleDegrees: Float) -> Float {
    let halfAngle = min(max(beamAngleDegrees, 1), 179) * .pi / 360
    return max(log(0.5) / log(max(cos(halfAngle), 0.001)), 0.001)
  }

  /// Effective solid angle for an energy-normalized cosine-power emitter.
  static func cobEffectiveSolidAngle(beamAngleDegrees: Float) -> Float {
    2 * .pi / (cobDistributionExponent(beamAngleDegrees: beamAngleDegrees) + 1)
  }

  /// Approximate 10% field edge used to fade a COB reflector without a hard cone boundary.
  static func cobFieldEdgeCosine(beamAngleDegrees: Float) -> Float {
    let exponent = cobDistributionExponent(beamAngleDegrees: beamAngleDegrees)
    return pow(0.1, 1 / exponent)
  }

  static func measurement(for light: VirtualLight) -> LightMeasurement? {
    guard let target = light.targetPosition?.simd else { return nil }
    let delta = target - light.position.simd
    let distance = simd_length(delta)
    guard distance > 0.001 else { return nil }
    let horizontal = hypot(delta.x, delta.z)
    let elevation = atan2(abs(delta.y), max(horizontal, 0.001)) * 180 / .pi
    let targetNormal = light.targetSurfaceNormal?.simd
    let towardLight = -delta / distance
    let incidence =
      targetNormal.map {
        max(simd_dot(simd_normalize($0), towardLight), 0)
      } ?? 1
    let lux = estimatedIlluminance(from: light, at: target, surfaceNormal: targetNormal)
    return LightMeasurement(
      distance: distance,
      elevationDegrees: elevation,
      incidence: incidence,
      beamDiameter: beamRadius(distance: distance, beamAngleDegrees: light.beamAngle) * 2,
      fixtureOutputMultiplier: 1,
      estimatedCenterLux: lux
    )
  }

  /// Smooth-edged COB spotlight energy at a world point, including inverse-square falloff.
  static func estimatedIlluminance(
    from light: VirtualLight,
    at worldPoint: SIMD3<Float>,
    surfaceNormal: SIMD3<Float>? = nil
  ) -> Float {
    guard light.enabled, light.intensity > 0, light.targetPosition != nil else { return 0 }
    let forward = effectiveDirection(for: light)
    let delta = worldPoint - light.position.simd
    let distance = simd_length(delta)
    guard distance > 0.02 else { return 0 }
    let ray = delta / distance
    let cosine = simd_dot(forward, ray)
    let halfPower = cos(min(max(light.beamAngle, 1), 179) * .pi / 360)
    let fieldEdge = cobFieldEdgeCosine(beamAngleDegrees: light.beamAngle)
    guard cosine > fieldEdge else { return 0 }
    let exponent = cobDistributionExponent(beamAngleDegrees: light.beamAngle)
    let edgeFade = smoothstep(
      edge0: fieldEdge, edge1: min(fieldEdge + 0.04, halfPower), value: cosine)
    let beamDistribution = pow(max(cosine, 0), exponent) * edgeFade
    let towardLight = -ray
    let incidence =
      surfaceNormal.map {
        max(simd_dot(simd_normalize($0), towardLight), 0)
      } ?? 1
    let lumens = light.ratedLumens * light.intensity / 100
    let candela = lumens / cobEffectiveSolidAngle(beamAngleDegrees: light.beamAngle)
    return candela / max(distance * distance, 0.04) * incidence * beamDistribution
  }

  /// RealityKit models conventionally face -Z. This quaternion rotates -Z toward direction.
  static func orientation(facing direction: SIMD3<Float>) -> simd_quatf? {
    let length = simd_length(direction)
    guard length > .ulpOfOne else { return nil }
    return simd_quatf(from: SIMD3<Float>(0, 0, -1), to: direction / length)
  }

  static func angularErrorDegrees(light: VirtualLight) -> Float? {
    guard let target = light.targetPosition?.simd,
      let desired = direction(from: light.position.simd, to: target)
    else { return nil }
    let stored = light.orientation.simd.act(SIMD3<Float>(0, 0, -1))
    let cosine = min(max(simd_dot(simd_normalize(stored), desired), -1), 1)
    return acos(cosine) * 180 / .pi
  }

  static func effectiveDirection(for light: VirtualLight) -> SIMD3<Float> {
    simd_normalize(light.orientation.simd.act(SIMD3<Float>(0, 0, -1)))
  }

  static func aimedPoint(for light: VirtualLight) -> SIMD3<Float>? {
    guard let target = light.targetPosition?.simd else { return nil }
    let distance = simd_distance(light.position.simd, target)
    return light.position.simd + effectiveDirection(for: light) * distance
  }

  static func orientationWithAimOffsets(for light: VirtualLight) -> simd_quatf? {
    guard let target = light.targetPosition?.simd,
      let baseDirection = direction(from: light.position.simd, to: target)
    else { return nil }
    let yaw = simd_quatf(angle: light.panOffset * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
    let yawed = simd_normalize(yaw.act(baseDirection))
    var right = simd_cross(yawed, SIMD3<Float>(0, 1, 0))
    if simd_length(right) < 0.001 { right = SIMD3<Float>(1, 0, 0) }
    let pitch = simd_quatf(angle: light.tiltOffset * .pi / 180, axis: simd_normalize(right))
    return orientation(facing: simd_normalize(pitch.act(yawed)))
  }

  private static func smoothstep(edge0: Float, edge1: Float, value: Float) -> Float {
    guard edge1 != edge0 else { return value >= edge1 ? 1 : 0 }
    let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
  }

  private static func linearToSRGB(_ value: Float) -> Float {
    value <= 0.0031308
      ? value * 12.92
      : 1.055 * pow(value, 1 / 2.4) - 0.055
  }
}

extension SIMD3 where Scalar == Float {
  fileprivate nonisolated func clamped(lower: Float, upper: Float) -> SIMD3<Float> {
    simd_min(simd_max(self, SIMD3(repeating: lower)), SIMD3(repeating: upper))
  }
}
