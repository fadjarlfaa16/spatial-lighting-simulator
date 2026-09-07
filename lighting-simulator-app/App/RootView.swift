//
//  RootView.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//


import SwiftUI

struct RootView: View {
    @ObservedObject var container: DependencyContainer
    @ObservedObject private var router: AppRouter

    init(container: DependencyContainer) {
        self.container = container
        self.router = container.router
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            ProjectView(
                presenter: ProjectPresenter(
                    interactor: ProjectInteractor(store: container.store),
                    router: ProjectRouter(appRouter: container.router)
                )
            )
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
            }
        }
        .task { await container.store.load() }
        .alert("Lighting Simulator", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { container.store.userMessage = nil }
        } message: {
            Text(container.store.userMessage ?? "")
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .subjectPlacement:
            SubjectPlacementView(presenter: SubjectPlacementPresenter(
                interactor: SubjectPlacementInteractor(store: container.store, arService: container.arSessionService),
                router: SubjectPlacementRouter(appRouter: container.router)
            ))
        case .lightPlacement:
            LightPlacementView(presenter: LightPlacementPresenter(
                interactor: LightPlacementInteractor(store: container.store, arService: container.arSessionService),
                router: LightPlacementRouter(appRouter: container.router)
            ))
        case .captureReview:
            CaptureReviewView(presenter: CaptureReviewPresenter(
                interactor: CaptureReviewInteractor(
                    store: container.store,
                    arService: container.arSessionService,
                    compressor: container.photoCompressor
                ),
                router: CaptureReviewRouter(appRouter: container.router)
            ))
        case .editor(let shotID):
            EditorView(presenter: EditorPresenter(
                interactor: EditorInteractor(
                    store: container.store,
                    estimator: container.normalEstimator,
                    shotID: shotID
                ),
                router: EditorRouter(appRouter: container.router)
            ))
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(
            get: { container.store.userMessage != nil },
            set: { if !$0 { container.store.userMessage = nil } }
        )
    }
}
