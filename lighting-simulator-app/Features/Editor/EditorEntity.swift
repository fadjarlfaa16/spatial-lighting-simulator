import CoreGraphics
import Foundation

enum EditorDisplayMode: String, CaseIterable, Identifiable {
    case relit = "Relit"
    case original = "Original"
    case normal = "Normal"
    case mask = "Mask"
    var id: String { rawValue }
}

struct EditorEntity {
    var photo: CGImage?
    var normalVisualization: CGImage?
    var maskVisualization: CGImage?
    var resources: MetalRelightingResources?
    var plan: SpatialPlanSnapshot?
    var parameters: RelightingParameters = .empty
    var selectedLightID: UUID?
    var phase: AnalysisPhase = .idle
    var displayMode: EditorDisplayMode = .relit
    var isCleanPreview = false
    var isExporting = false
    var inferenceSummary: String?
    var mediaKind: ProjectMediaKind = .photo

    var selectedWorldLight: VirtualLight? {
        plan?.lights.first { $0.id == selectedLightID } ?? plan?.lights.first
    }
}
