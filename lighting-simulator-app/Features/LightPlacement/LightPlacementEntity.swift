import Foundation

struct LightPlacementEntity: Equatable {
    var subject: PlannedSubject?
    var lights: [VirtualLight]
    var selectedLightID: UUID?
    var placementPreview: WorldRaycastHit?
    var debugSnapshot: SpatialDebugSnapshot

    var selectedLight: VirtualLight? {
        lights.first { $0.id == selectedLightID } ?? lights.last
    }
    var canAddLight: Bool { lights.count < LightingProject.maximumLightCount }
    var isReadyForPreview: Bool { !lights.isEmpty }
}
