//
//  LightingSimulatorApp.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//


import SwiftUI

@main
struct LightingSimulatorApp: App {
    @StateObject private var container = DependencyContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .preferredColorScheme(.dark)
        }
    }
}
