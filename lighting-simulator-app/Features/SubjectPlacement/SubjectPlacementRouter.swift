@MainActor
protocol SubjectPlacementRouting: AnyObject { func showLightPlacement() }

@MainActor
final class SubjectPlacementRouter: SubjectPlacementRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showLightPlacement() { appRouter.show(.lightPlacement) }
}
