//
//  AppRouter.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import Combine
import Foundation

enum AppRoute: Hashable {
    case subjectPlacement
    case captureReview
    case editor(UUID)
    case videoCapture(UUID)
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [AppRoute] = []

    func show(_ route: AppRoute) { path.append(route) }
    func back() { if !path.isEmpty { path.removeLast() } }
    func returnToProjects() { path.removeAll() }
}
