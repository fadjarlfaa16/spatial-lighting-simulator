//
//  Theme+Extension.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import SwiftUI

enum AppTheme {
    static let backgroundTop = Color(red: 0.055, green: 0.067, blue: 0.086)
    static let backgroundBottom = Color(red: 0.018, green: 0.024, blue: 0.034)
    static let surface = Color(red: 0.075, green: 0.086, blue: 0.105)
    static let surfaceRaised = Color(red: 0.095, green: 0.108, blue: 0.13)
    static let border = Color.white.opacity(0.10)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.60, green: 0.64, blue: 0.71)
    static let primary = Color(red: 0.08, green: 0.55, blue: 1.0)
    static let primaryBright = Color(red: 0.20, green: 0.72, blue: 1.0)
    static let placement = Color(red: 1.0, green: 0.52, blue: 0.16)
    static let destructive = Color(red: 1.0, green: 0.30, blue: 0.32)

    static let pageBackground = LinearGradient(
        colors: [backgroundTop, backgroundBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(
                tint.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct StudioSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.textPrimary.opacity(configuration.isPressed ? 0.65 : 1))
            .padding(.horizontal, 16)
            .frame(minHeight: 42)
            .background(AppTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(AppTheme.border))
    }
}

struct StudioIconButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.55 : 1))
            .frame(width: 42, height: 42)
            .background(AppTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(AppTheme.border))
    }
}
