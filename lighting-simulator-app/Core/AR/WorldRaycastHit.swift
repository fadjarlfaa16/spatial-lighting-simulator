//
//  WorldRaycastHit.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import Foundation

nonisolated struct WorldRaycastHit: Equatable, Sendable {
  var position: SpatialVector
  var normal: SpatialVector
  var isHorizontal: Bool
}
