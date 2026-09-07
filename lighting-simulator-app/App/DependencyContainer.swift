//
//  DependencyContainer.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//


import Combine
import Foundation

@MainActor
final class DependencyContainer: ObservableObject {
  let router: AppRouter
  let store: AppSessionStore
  let arSessionService: ARSessionService
  let normalEstimator: any NormalEstimating
  let photoCompressor: any PhotoCompressing

  convenience init() {
    self.init(
      repository: JSONProjectRepository(),
      arSessionService: ARSessionService(),
      normalEstimator: SapiensNormalEstimator(),
      photoCompressor: PhotoCompressor()
    )
  }

  init(
    repository: ProjectRepositoryProtocol,
    arSessionService: ARSessionService,
    normalEstimator: any NormalEstimating,
    photoCompressor: any PhotoCompressing
  ) {
    router = AppRouter()
    store = AppSessionStore(repository: repository)
    self.arSessionService = arSessionService
    self.normalEstimator = normalEstimator
    self.photoCompressor = photoCompressor
  }
}
