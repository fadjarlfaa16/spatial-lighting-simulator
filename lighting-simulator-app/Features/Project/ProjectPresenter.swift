import Combine
import Foundation

@MainActor
final class ProjectPresenter: ObservableObject {
    @Published private(set) var projects: [ProjectRowEntity] = []
    @Published private(set) var openingProjectID: UUID?
    @Published var errorMessage: String?

    private let interactor: ProjectInteractorProtocol
    private let router: ProjectRouting
    private var cancellables = Set<AnyCancellable>()
    private var thumbnailTask: Task<Void, Never>?

    init(interactor: ProjectInteractorProtocol, router: ProjectRouting) {
        self.interactor = interactor
        self.router = router
        interactor.projectsPublisher
            .sink { [weak self] in self?.receive($0) }
            .store(in: &cancellables)
    }

    private func receive(_ values: [LightingProject]) {
        let existing = Dictionary(uniqueKeysWithValues: projects.compactMap { row in
            row.thumbnail.map { (row.id, $0) }
        })
        projects = values.map { project in
            var row = ProjectRowEntity(project: project)
            row.thumbnail = existing[project.id]
            return row
        }
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            for project in values where existing[project.id] == nil {
                guard !Task.isCancelled else { return }
                let image = await interactor.thumbnail(projectID: project.id)
                guard !Task.isCancelled,
                      let index = projects.firstIndex(where: { $0.id == project.id }) else { continue }
                projects[index].thumbnail = image
            }
        }
    }

    func createProject(mediaKind: ProjectMediaKind) {
        interactor.beginProject(mediaKind: mediaKind)
        router.showSubjectPlacement()
    }

    func openProject(_ id: UUID) {
        guard openingProjectID == nil else { return }
        openingProjectID = id
        Task {
            defer { openingProjectID = nil }
            do {
                let shotID = try await interactor.openProject(id: id)
                router.showEditor(shotID: shotID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
