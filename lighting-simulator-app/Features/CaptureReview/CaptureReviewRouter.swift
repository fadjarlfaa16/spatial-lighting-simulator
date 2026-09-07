import Foundation

@MainActor
protocol CaptureReviewRouting: AnyObject {
    func showEditor(shotID: UUID)
}

@MainActor
final class CaptureReviewRouter: CaptureReviewRouting {
    private let appRouter: AppRouter
    init(appRouter: AppRouter) { self.appRouter = appRouter }
    func showEditor(shotID: UUID) { appRouter.show(.editor(shotID)) }
}
