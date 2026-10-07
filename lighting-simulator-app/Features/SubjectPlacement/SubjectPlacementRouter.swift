@MainActor
protocol SubjectPlacementRouting: AnyObject { func showCapture() }

@MainActor
final class SubjectPlacementRouter: SubjectPlacementRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showCapture() { appRouter.show(.captureReview) }
}
