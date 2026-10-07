import SwiftUI

struct CaptureReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter: CaptureReviewPresenter

    init(presenter: CaptureReviewPresenter) {
        _presenter = StateObject(wrappedValue: presenter)
    }

    var body: some View {
        StudioCameraLayout(
            backAction: {
                if presenter.entity.draft == nil {
                    dismiss()
                } else {
                    presenter.retake()
                }
            },
            canvas: { cameraCanvas },
            inspector: { inspector }
        )
        .alert("Capture", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { presenter.errorMessage = nil }
        } message: {
            Text(presenter.errorMessage ?? "")
        }
        .alert("Name Project", isPresented: $presenter.isNamingProject) {
            TextField("Project name", text: $presenter.projectName)
            Button("Cancel", role: .cancel) {}
            Button("Save & Open Editor", action: presenter.proceed)
                .disabled(presenter.projectName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
        } message: {
            Text("The project is saved only after this photo is confirmed.")
        }
    }

    @ViewBuilder private var cameraCanvas: some View {
        if let draft = presenter.entity.draft {
            ZStack {
                Color.black
                Image(decorative: draft.preview, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
        } else {
            ZStack {
                ARViewContainer(
                    sessionService: presenter.arService,
                    content: ARSceneContent(
                        subject: nil,
                        lights: [],
                        selectedLightID: nil,
                        placementPreview: nil,
                        showAnchors: false,
                        showLightDirection: false
                    )
                )
                CameraCrosshair()
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioGuideHeader(
                step: "Step 2 of 2",
                title: presenter.entity.draft == nil ? "Compose the shot" : "Review photo",
                detail: presenter.entity.draft == nil
                    ? "Compose the frame, hold the device steady, then press the shutter."
                    : "Check the orientation and composition before opening the editor."
            )

            Divider().overlay(AppTheme.border)

            Label(presenter.entity.phase.message, systemImage: phaseIcon)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            Spacer()

            if presenter.entity.draft == nil {
                CameraShutterButton(
                    isBusy: presenter.entity.phase == .capturing,
                    action: presenter.capture
                )
                .frame(maxWidth: .infinity)
                .disabled(!presenter.entity.canCapture)
                .opacity(presenter.entity.canCapture ? 1 : 0.5)
            } else {
                Button(action: presenter.retake) {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(presenter.entity.phase == .savingProject)

                Button(action: presenter.requestProceed) {
                    Label("Proceed to Editor", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(presenter.entity.phase == .savingProject)
            }
        }
        .padding(18)
    }

    private var phaseIcon: String {
        switch presenter.entity.phase {
        case .capturing, .savingProject: "hourglass"
        case .failed: "exclamationmark.triangle"
        default: "camera"
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { presenter.errorMessage != nil },
            set: { if !$0 { presenter.errorMessage = nil } }
        )
    }
}
