import Combine
import CoreGraphics
import Foundation

@MainActor
protocol ProjectInteractorProtocol: AnyObject {
    var projectsPublisher: AnyPublisher<[LightingProject], Never> { get }
    func beginProject()
    func openProject(id: UUID) async throws -> UUID
    func thumbnail(projectID: UUID) async -> CGImage?
}

@MainActor
final class ProjectInteractor: ProjectInteractorProtocol {
    private let store: AppSessionStore

    init(store: AppSessionStore) { self.store = store }

    var projectsPublisher: AnyPublisher<[LightingProject], Never> {
        store.$projects.eraseToAnyPublisher()
    }

    func beginProject() { store.beginDraftProject() }

    func openProject(id: UUID) async throws -> UUID {
        try await store.prepareEditor(projectID: id)
    }

    func thumbnail(projectID: UUID) async -> CGImage? {
        guard let project = store.projects.first(where: { $0.id == projectID }),
              let shot = project.shots.max(by: { $0.timestamp < $1.timestamp }),
              let fileName = shot.imageFileName,
              let data = try? await store.repository.imageData(fileName: fileName) else {
            return nil
        }
        return try? await Task.detached(priority: .utility) {
            try ImageOrientationNormalizer(maximumPixelDimension: 512)
                .normalize(data: data)
        }.value
    }
}
