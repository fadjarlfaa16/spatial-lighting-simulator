import SwiftUI

struct SubjectPlacementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter: SubjectPlacementPresenter

    init(presenter: SubjectPlacementPresenter) {
        _presenter = StateObject(wrappedValue: presenter)
    }

    var body: some View {
        StudioCameraLayout(
            backAction: {
                presenter.arService.stopAndRelease()
                dismiss()
            },
            canvas: {
                ZStack {
                    ARViewContainer(
                        sessionService: presenter.arService,
                        content: ARSceneContent(
                            subject: presenter.entity.subject,
                            lights: [],
                            selectedLightID: nil,
                            placementPreview: nil,
                            showAnchors: false,
                            showLightDirection: false
                        )
                    )
                    CameraCrosshair()
                }
            },
            inspector: { guide }
        )
        .task { await presenter.start() }
        .alert("Placement failed", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { presenter.errorMessage = nil }
        } message: {
            Text(presenter.errorMessage ?? "")
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioGuideHeader(
                step: "Step 1 of 2",
                title: "Place the subject",
                detail: "Aim the reticle at the floor where the subject will stand, then save the position."
            )

            Divider().overlay(AppTheme.border)

            Label(
                presenter.entity.subject == nil ? "Not placed" : "Subject position saved",
                systemImage: presenter.entity.subject == nil
                    ? "scope" : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(
                presenter.entity.subject == nil
                    ? AppTheme.textSecondary : AppTheme.primaryBright
            )

            Spacer()

            HStack(spacing: 12) {
                Button(action: presenter.placeSubject) {
                    Label(
                        presenter.entity.subject == nil ? "Place Subject" : "Move Subject",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioPrimaryButtonStyle())

                Button(action: presenter.toggleCamera) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(StudioSecondaryButtonStyle())
            }

            Button(action: presenter.continueToCapture) {
                Label("Continue to Camera", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .disabled(presenter.entity.subject == nil)
            .opacity(presenter.entity.subject == nil ? 0.38 : 1)
        }
        .padding(18)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { presenter.errorMessage != nil },
            set: { if !$0 { presenter.errorMessage = nil } }
        )
    }
}
