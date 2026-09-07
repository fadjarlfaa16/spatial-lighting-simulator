import Foundation

@MainActor
protocol ProjectRouting: AnyObject {
    func showSubjectPlacement()
    func showEditor(shotID: UUID)
}

@MainActor
final class ProjectRouter: ProjectRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showSubjectPlacement() { appRouter.show(.subjectPlacement) }
    func showEditor(shotID: UUID) { appRouter.show(.editor(shotID)) }
}
