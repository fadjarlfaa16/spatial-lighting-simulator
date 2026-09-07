@MainActor
protocol EditorRouting: AnyObject { func showProjects() }

@MainActor
final class EditorRouter: EditorRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showProjects() { appRouter.returnToProjects() }
}
