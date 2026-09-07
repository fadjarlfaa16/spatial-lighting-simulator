import CoreGraphics
import Foundation

struct ProjectRowEntity: Identifiable {
    let id: UUID
    let name: String
    let updatedAt: Date
    let shotCount: Int
    var thumbnail: CGImage?

    init(project: LightingProject) {
        id = project.id
        name = project.name
        updatedAt = project.updatedAt
        shotCount = project.shots.count
        thumbnail = nil
    }
}
