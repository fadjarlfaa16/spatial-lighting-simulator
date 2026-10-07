import Foundation

@MainActor
protocol VideoCaptureRouting: AnyObject { func showProjects() }

@MainActor
final class VideoCaptureRouter: VideoCaptureRouting {
  private let appRouter: AppRouter

  init(appRouter: AppRouter) { self.appRouter = appRouter }

  func showProjects() { appRouter.returnToProjects() }
}
