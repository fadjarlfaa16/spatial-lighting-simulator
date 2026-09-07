import ARKit
import Combine
import Foundation

@MainActor
protocol LightPlacementInteractorProtocol: AnyObject {
  var arService: ARSessionService { get }
  var statePublisher: AnyPublisher<LightPlacementEntity, Never> { get }
  var debugSettings: DebugSettings { get }
  func selectLight(id: UUID)
  func placeLight() throws
  func moveSelectedLight() throws
  func removeSelectedLight()
}

@MainActor
final class LightPlacementInteractor: LightPlacementInteractorProtocol {
  let arService: ARSessionService
  private let store: AppSessionStore
  private let selectedLightID: CurrentValueSubject<UUID?, Never>
  private let placementPreview = CurrentValueSubject<WorldRaycastHit?, Never>(nil)
  private var cancellables = Set<AnyCancellable>()

  init(store: AppSessionStore, arService: ARSessionService) {
    self.store = store
    self.arService = arService
    selectedLightID = CurrentValueSubject(store.currentProject?.lights.first?.id)

    arService.$cameraTransform
      .compactMap { $0 }
      .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
      .sink { [weak self] _ in
        guard let self else { return }
        self.placementPreview.send(
          try? arService.raycastHitFromCameraCenter(
            alignment: .horizontal,
            context: "flat light placement surface"
          )
        )
      }
      .store(in: &cancellables)
  }

  var debugSettings: DebugSettings { store.debugSettings }

  var statePublisher: AnyPublisher<LightPlacementEntity, Never> {
    let selectionAndPreview = Publishers.CombineLatest(selectedLightID, placementPreview)
    return Publishers.CombineLatest4(
      store.$currentProject,
      arService.$cameraTransform,
      arService.$trackingDescription,
      selectionAndPreview
    )
    .map { [capabilities = arService.capabilities] project, cameraTransform, tracking, selection in
      let subject = project?.subject
      let lights = project?.lights ?? []
      let selectedID = selection.0 ?? lights.last?.id
      let selected = lights.first { $0.id == selectedID } ?? lights.last
      let camera = cameraTransform?.translation
      return LightPlacementEntity(
        subject: subject,
        lights: lights,
        selectedLightID: selected?.id,
        placementPreview: lights.count < LightingProject.maximumLightCount ? selection.1 : nil,
        debugSnapshot: SpatialDebugSnapshot(
          tracking: tracking,
          camera: camera.map(SpatialVector.init),
          subject: subject?.position,
          light: selected?.position,
          cameraToSubject: Self.distance(camera, subject?.position.simd),
          lightToSubject: Self.distance(selected?.position.simd, subject?.position.simd),
          capabilities: capabilities,
          lightCount: lights.count
        )
      )
    }
    .eraseToAnyPublisher()
  }

  func selectLight(id: UUID) {
    guard store.currentProject?.lights.contains(where: { $0.id == id }) == true else { return }
    selectedLightID.send(id)
  }

  func placeLight() throws {
    guard let project = store.currentProject,
      project.lights.count < LightingProject.maximumLightCount
    else {
      throw LightPlacementError.maximumLightsReached
    }
    guard let hit = placementPreview.value, hit.isHorizontal else {
      throw LightPlacementError.flatSurfaceRequired
    }
    let index = project.lights.count
    let names = ["Key Light", "Fill Light", "Rim Light"]
    let height: Float = 1.8
    guard let subject = project.subject else {
      throw LightPlacementError.targetRequired
    }
    let target = subject.position.simd + SIMD3(0, SpatialMath.defaultSubjectAimHeight, 0)
    guard
          let direction = SpatialMath.direction(
            from: hit.position.simd + SIMD3(0, height, 0),
            to: target
          ), let orientation = SpatialMath.orientation(facing: direction) else {
      throw LightPlacementError.targetRequired
    }
    let light = VirtualLight(
      name: names[index],
      position: SpatialVector(hit.position.simd + SIMD3(0, height, 0)),
      orientation: SpatialQuaternion(orientation),
      targetPosition: SpatialVector(target),
      height: height
    )
    store.updateCurrent { $0.lights.append(light) }
    selectedLightID.send(light.id)
  }

  func moveSelectedLight() throws {
    guard let hit = placementPreview.value, hit.isHorizontal else {
      throw LightPlacementError.flatSurfaceRequired
    }
    try mutateSelected { light in
      light.position = SpatialVector(hit.position.simd + SIMD3(0, light.height, 0))
      guard let target = light.targetPosition?.simd else {
        throw LightPlacementError.targetRequired
      }
      light.panOffsetDegrees = 0
      light.tiltOffsetDegrees = 0
      guard SpatialMath.direction(from: light.position.simd, to: target) != nil,
        let orientation = SpatialMath.orientationWithAimOffsets(for: light)
      else {
        throw LightPlacementError.targetTooClose
      }
      light.orientation = SpatialQuaternion(orientation)
    }
  }

  func removeSelectedLight() {
    guard let id = effectiveSelectedID else { return }
    store.updateCurrent { $0.lights.removeAll { $0.id == id } }
    selectedLightID.send(store.currentProject?.lights.last?.id)
  }

  private var effectiveSelectedID: UUID? {
    selectedLightID.value ?? store.currentProject?.lights.last?.id
  }

  private func mutateSelected(_ mutation: (inout VirtualLight) throws -> Void) throws {
    guard let id = effectiveSelectedID,
      let project = store.currentProject,
      let index = project.lights.firstIndex(where: { $0.id == id })
    else {
      throw LightPlacementError.lightRequired
    }
    var updatedLight = project.lights[index]
    try mutation(&updatedLight)
    store.updateCurrent { current in
      guard let currentIndex = current.lights.firstIndex(where: { $0.id == id }) else { return }
      current.lights[currentIndex] = updatedLight
    }
  }

  private static func distance(_ first: SIMD3<Float>?, _ second: SIMD3<Float>?) -> Float? {
    guard let first, let second else { return nil }
    return SpatialMath.distance(first, second)
  }
}

enum LightPlacementError: LocalizedError {
  case maximumLightsReached
  case flatSurfaceRequired
  case lightRequired
  case targetRequired
  case targetTooClose

  var errorDescription: String? {
    switch self {
    case .maximumLightsReached: return "A maximum of three lights can be placed."
    case .flatSurfaceRequired:
      return "Aim at a detected flat horizontal surface before placing the fixture."
    case .lightRequired: return "Select or place a light first."
    case .targetRequired: return "Set a target before refocusing the fixture."
    case .targetTooClose: return "The target is too close to the fixture to calculate a direction."
    }
  }
}
