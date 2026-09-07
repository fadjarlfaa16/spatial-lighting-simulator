import SwiftUI

struct StudioCameraLayout<Canvas: View, Inspector: View>: View {
    let backAction: () -> Void
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let inspector: () -> Inspector

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.pageBackground.ignoresSafeArea()

                VStack(spacing: 10) {
                    HStack {
                        Button(action: backAction) {
                            Image(systemName: "chevron.left")
                                .accessibilityLabel("Back")
                        }
                        .buttonStyle(StudioIconButtonStyle())
                        Spacer()
                    }
                    .frame(height: 44)

                    HStack(spacing: 14) {
                        canvas()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(AppTheme.border)
                            )

                        inspector()
                            .frame(width: inspectorWidth(for: proxy.size.width))
                            .frame(maxHeight: .infinity)
                            .background(
                                AppTheme.surface.opacity(0.94),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(AppTheme.border)
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .foregroundStyle(AppTheme.textPrimary)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func inspectorWidth(for totalWidth: CGFloat) -> CGFloat {
        min(max(totalWidth * 0.28, 260), 340)
    }
}

struct StudioGuideHeader: View {
    let step: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(step.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.primaryBright)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CameraShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 62, height: 62)
                Circle().fill(.white)
                    .frame(width: 50, height: 50)
                if isBusy {
                    ProgressView().tint(.black)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Capture photo")
    }
}
