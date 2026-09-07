@MainActor
protocol LightPlacementRouting: AnyObject { func showCapture() }

@MainActor
final class LightPlacementRouter: LightPlacementRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showCapture() { appRouter.show(.captureReview) }
}
