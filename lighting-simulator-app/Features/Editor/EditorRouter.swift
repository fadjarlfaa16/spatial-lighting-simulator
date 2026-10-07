import Foundation

@MainActor
protocol EditorRouting: AnyObject {
    func showProjects()
    func showVideoCapture(shotID: UUID)
}

@MainActor
final class EditorRouter: EditorRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showProjects() { appRouter.returnToProjects() }
    func showVideoCapture(shotID: UUID) { appRouter.show(.videoCapture(shotID)) }
}
