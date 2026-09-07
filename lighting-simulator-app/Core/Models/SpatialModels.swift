import Foundation
import simd

nonisolated struct SpatialVector: Codable, Equatable, Sendable {
  var x: Float
  var y: Float
  var z: Float

  init(x: Float, y: Float, z: Float) {
    self.x = x
    self.y = y
    self.z = z
  }

  init(_ value: SIMD3<Float>) {
    self.init(x: value.x, y: value.y, z: value.z)
  }

  var simd: SIMD3<Float> { SIMD3(x, y, z) }
  static let zero = SpatialVector(.zero)
}

nonisolated struct SpatialQuaternion: Codable, Equatable, Sendable {
  var x: Float
  var y: Float
  var z: Float
  var w: Float

  init(_ value: simd_quatf) {
    x = value.imag.x
    y = value.imag.y
    z = value.imag.z
    w = value.real
  }

  var simd: simd_quatf {
    simd_normalize(simd_quatf(ix: x, iy: y, iz: z, r: w))
  }

  static let identity = SpatialQuaternion(simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
}

nonisolated struct SpatialTransform: Codable, Equatable, Sendable {
  /// Column-major 4x4 transform, matching simd_float4x4/ARKit.
  var values: [Float]

  init(_ matrix: simd_float4x4) {
    values = [
      matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
      matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
      matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
      matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w,
    ]
  }

  var matrix: simd_float4x4 {
    guard values.count == 16 else { return matrix_identity_float4x4 }
    return simd_float4x4(
      SIMD4(values[0], values[1], values[2], values[3]),
      SIMD4(values[4], values[5], values[6], values[7]),
      SIMD4(values[8], values[9], values[10], values[11]),
      SIMD4(values[12], values[13], values[14], values[15])
    )
  }

  var position: SpatialVector { SpatialVector(matrix.translation) }
}

/// Orientation of the captured JPEG's displayed pixel space. Keeping it with
/// the AR intrinsics lets the editor project world points into the same
/// coordinate system after ImageIO consumes the EXIF transform exactly once.
nonisolated enum CapturedImageOrientation: String, Codable, Equatable, Sendable {
  case up, down, left, right

  /// EXIF orientation written beside an unrotated camera pixel buffer.
  var exifRawValue: Int {
    switch self {
    case .up: 1
    case .down: 3
    case .left: 8
    case .right: 6
    }
  }

  init(exifRawValue: Int, fallback: CapturedImageOrientation = .up) {
    switch exifRawValue {
    case 3, 4: self = .down
    case 5, 8: self = .left
    case 6, 7: self = .right
    case 1, 2: self = .up
    default: self = fallback
    }
  }

  func orient(normalized point: SIMD2<Float>) -> SIMD2<Float> {
    switch self {
    case .up: point
    case .down: SIMD2(1 - point.x, 1 - point.y)
    case .left: SIMD2(point.y, 1 - point.x)
    case .right: SIMD2(1 - point.y, point.x)
    }
  }
}

nonisolated struct CameraCalibration: Codable, Equatable, Sendable {
  let fx: Float
  let fy: Float
  let cx: Float
  let cy: Float
  let sensorWidth: Float
  let sensorHeight: Float
  let imageOrientation: CapturedImageOrientation

  var orientedWidth: Float {
    imageOrientation == .left || imageOrientation == .right ? sensorHeight : sensorWidth
  }

  var orientedHeight: Float {
    imageOrientation == .left || imageOrientation == .right ? sensorWidth : sensorHeight
  }

  func withImageOrientation(_ orientation: CapturedImageOrientation) -> CameraCalibration {
    CameraCalibration(
      fx: fx, fy: fy, cx: cx, cy: cy,
      sensorWidth: sensorWidth, sensorHeight: sensorHeight,
      imageOrientation: orientation
    )
  }
}

nonisolated struct RoomBoundary: Codable, Equatable, Sendable {
  var minimumX: Float
  var maximumX: Float
  var minimumZ: Float
  var maximumZ: Float

  mutating func include(_ point: SIMD3<Float>, padding: Float = 0.25) {
    minimumX = min(minimumX, point.x - padding)
    maximumX = max(maximumX, point.x + padding)
    minimumZ = min(minimumZ, point.z - padding)
    maximumZ = max(maximumZ, point.z + padding)
  }

  static func around(_ point: SIMD3<Float>, radius: Float = 2) -> RoomBoundary {
    RoomBoundary(
      minimumX: point.x - radius,
      maximumX: point.x + radius,
      minimumZ: point.z - radius,
      maximumZ: point.z + radius
    )
  }
}

nonisolated struct PlannedSubject: Identifiable, Codable, Equatable, Sendable {
  var id = UUID()
  var position: SpatialVector
}

nonisolated struct VirtualLight: Identifiable, Codable, Equatable, Sendable {
  var id = UUID()
  var name = "Key Light"
  /// World-space position of the fixture head, not a camera-relative offset.
  var position: SpatialVector
  var orientation: SpatialQuaternion = .identity
  var targetPosition: SpatialVector?
  /// World-space surface normal returned by the target raycast, when available.
  var targetSurfaceNormal: SpatialVector?
  var height: Float = 1.8
  var intensity: Float = 70
  var kelvin: Float = 5_600
  var beamAngle: Float = 45
  var enabled = true
  /// Optional fixture calibration. Nil uses the PoC COB reference output.
  var maximumLumens: Float?
  /// Manual head offsets relative to the locked target; optional for metadata migration.
  var panOffsetDegrees: Float?
  var tiltOffsetDegrees: Float?

  var ratedLumens: Float { maximumLumens ?? 12_000 }
  var isTargetLocked: Bool { targetPosition != nil }
  var panOffset: Float { panOffsetDegrees ?? 0 }
  var tiltOffset: Float { tiltOffsetDegrees ?? 0 }

  mutating func setHeight(_ newHeight: Float) {
    let clamped = min(max(newHeight, 0.2), 5)
    let floorY = position.y - height
    height = clamped
    position.y = floorY + clamped
  }
}

nonisolated struct LightFalloffEdit: Codable, Equatable, Sendable {
  let lightID: UUID
  var softness: Float
}

/// Values changed after capture. Persisting them separately from the spatial
/// plan keeps the AR measurements authoritative while allowing an old project
/// to reopen exactly where the editor was left.
nonisolated struct RelightingEditState: Codable, Equatable, Sendable {
  var ambientIntensity: Float
  var diffuseStrength: Float
  var specularStrength: Float
  var specularShininess: Float
  var lightFalloffs: [LightFalloffEdit]

  static let initial = RelightingEditState(
    ambientIntensity: 0.58,
    diffuseStrength: 0.52,
    specularStrength: 0.02,
    specularShininess: 64,
    lightFalloffs: []
  )

  init(
    ambientIntensity: Float,
    diffuseStrength: Float,
    specularStrength: Float,
    specularShininess: Float,
    lightFalloffs: [LightFalloffEdit]
  ) {
    self.ambientIntensity = ambientIntensity
    self.diffuseStrength = diffuseStrength
    self.specularStrength = specularStrength
    self.specularShininess = specularShininess
    self.lightFalloffs = lightFalloffs
  }

  init(parameters: RelightingParameters) {
    ambientIntensity = parameters.ambientIntensity
    diffuseStrength = parameters.diffuseStrength
    specularStrength = parameters.specularStrength
    specularShininess = parameters.specularShininess
    lightFalloffs = parameters.lights.map {
      LightFalloffEdit(lightID: $0.id, softness: $0.falloffSoftness)
    }
  }

  func apply(to parameters: inout RelightingParameters) {
    parameters.ambientIntensity = ambientIntensity
    parameters.diffuseStrength = diffuseStrength
    parameters.specularStrength = specularStrength
    parameters.specularShininess = specularShininess
    let savedFalloffs = Dictionary(uniqueKeysWithValues: lightFalloffs.map {
      ($0.lightID, $0.softness)
    })
    for index in parameters.lights.indices {
      if let softness = savedFalloffs[parameters.lights[index].id] {
        parameters.lights[index].falloffSoftness = softness
      }
    }
  }
}

nonisolated struct Shot: Identifiable, Equatable, Sendable {
  var id = UUID()
  var projectID: UUID
  var imageFileName: String?
  var normalCacheFileName: String?
  var maskCacheFileName: String?
  var timestamp: Date
  var cameraTransform: SpatialTransform
  var cameraCalibration: CameraCalibration?
  var subjectPosition: SpatialVector
  var lights: [VirtualLight]
  var editState: RelightingEditState

  var cameraPosition: SpatialVector { cameraTransform.position }
  var primaryLight: VirtualLight? { lights.first }

  init(
    id: UUID = UUID(),
    projectID: UUID,
    imageFileName: String?,
    normalCacheFileName: String? = nil,
    maskCacheFileName: String? = nil,
    timestamp: Date,
    cameraTransform: SpatialTransform,
    cameraCalibration: CameraCalibration? = nil,
    subjectPosition: SpatialVector,
    lights: [VirtualLight],
    editState: RelightingEditState = .initial
  ) {
    self.id = id
    self.projectID = projectID
    self.imageFileName = imageFileName
    self.normalCacheFileName = normalCacheFileName
    self.maskCacheFileName = maskCacheFileName
    self.timestamp = timestamp
    self.cameraTransform = cameraTransform
    self.cameraCalibration = cameraCalibration
    self.subjectPosition = subjectPosition
    self.lights = Array(lights.prefix(LightingProject.maximumLightCount))
    self.editState = editState
  }
}

extension Shot: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, projectID, imageFileName, normalCacheFileName, maskCacheFileName,
         timestamp, cameraTransform, cameraCalibration,
         subjectPosition, lights, light, editState
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    projectID = try container.decode(UUID.self, forKey: .projectID)
    imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
    normalCacheFileName = try container.decodeIfPresent(String.self, forKey: .normalCacheFileName)
    maskCacheFileName = try container.decodeIfPresent(String.self, forKey: .maskCacheFileName)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    cameraTransform = try container.decode(SpatialTransform.self, forKey: .cameraTransform)
    cameraCalibration = try container.decodeIfPresent(CameraCalibration.self, forKey: .cameraCalibration)
    subjectPosition = try container.decode(SpatialVector.self, forKey: .subjectPosition)
    if let decodedLights = try container.decodeIfPresent([VirtualLight].self, forKey: .lights) {
      lights = Array(decodedLights.prefix(LightingProject.maximumLightCount))
    } else if let legacyLight = try container.decodeIfPresent(VirtualLight.self, forKey: .light) {
      lights = [legacyLight]
    } else {
      lights = []
    }
    editState = try container.decodeIfPresent(
      RelightingEditState.self,
      forKey: .editState
    ) ?? .initial
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(projectID, forKey: .projectID)
    try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
    try container.encodeIfPresent(normalCacheFileName, forKey: .normalCacheFileName)
    try container.encodeIfPresent(maskCacheFileName, forKey: .maskCacheFileName)
    try container.encode(timestamp, forKey: .timestamp)
    try container.encode(cameraTransform, forKey: .cameraTransform)
    try container.encodeIfPresent(cameraCalibration, forKey: .cameraCalibration)
    try container.encode(subjectPosition, forKey: .subjectPosition)
    try container.encode(lights, forKey: .lights)
    try container.encode(editState, forKey: .editState)
  }
}

nonisolated struct LightingProject: Identifiable, Codable, Equatable, Sendable {
  static let maximumLightCount = 3
  var id = UUID()
  var name: String
  var createdAt = Date()
  var updatedAt = Date()
  var subject: PlannedSubject?
  var lights: [VirtualLight] = []
  var shots: [Shot] = []
  var roomBoundary: RoomBoundary?

  var primaryLight: VirtualLight? {
    get { lights.first }
    set {
      if let newValue {
        if lights.isEmpty { lights.append(newValue) } else { lights[0] = newValue }
      } else {
        lights.removeAll()
      }
    }
  }
}

nonisolated struct LightMeasurement: Codable, Equatable, Sendable {
  var distance: Float
  var elevationDegrees: Float
  var incidence: Float
  var beamDiameter: Float
  /// Fixture-specific output calibration. Generic COB remains 1.0 for all CCT values.
  var fixtureOutputMultiplier: Float
  var estimatedCenterLux: Float
}

nonisolated struct SpatialDistance: Codable, Equatable, Sendable, Identifiable {
  var id: String { "\(fromID)-\(toID)" }
  let fromID: String
  let toID: String
  let meters: Float
}

/// Value-only handoff from AR planning to photo editing. It retains no ARSession,
/// ARFrame, CVPixelBuffer, anchor, or RealityKit entity.
nonisolated struct SpatialPlanSnapshot: Codable, Equatable, Sendable {
  let projectID: UUID
  let cameraTransform: SpatialTransform
  let cameraCalibration: CameraCalibration?
  let subjectPosition: SpatialVector
  var lights: [VirtualLight]
  let distances: [SpatialDistance]

  init(projectID: UUID, cameraTransform: SpatialTransform,
       cameraCalibration: CameraCalibration? = nil,
       subjectPosition: SpatialVector, lights: [VirtualLight]) {
    self.projectID = projectID
    self.cameraTransform = cameraTransform
    self.cameraCalibration = cameraCalibration
    self.subjectPosition = subjectPosition
    self.lights = Array(lights.prefix(LightingProject.maximumLightCount))

    let camera = cameraTransform.position.simd
    var values = [SpatialDistance(
      fromID: "camera", toID: "subject",
      meters: SpatialMath.distance(camera, subjectPosition.simd)
    )]
    for (index, light) in self.lights.enumerated() {
      let lightID = "light-\(index + 1)"
      values.append(SpatialDistance(
        fromID: "camera", toID: lightID,
        meters: SpatialMath.distance(camera, light.position.simd)
      ))
      values.append(SpatialDistance(
        fromID: lightID, toID: "subject",
        meters: SpatialMath.distance(light.position.simd, subjectPosition.simd)
      ))
      for otherIndex in 0..<index {
        values.append(SpatialDistance(
          fromID: "light-\(otherIndex + 1)", toID: lightID,
          meters: SpatialMath.distance(self.lights[otherIndex].position.simd, light.position.simd)
        ))
      }
    }
    distances = values
  }
}

extension simd_float4x4 {
  nonisolated var translation: SIMD3<Float> {
    SIMD3(columns.3.x, columns.3.y, columns.3.z)
  }
}
