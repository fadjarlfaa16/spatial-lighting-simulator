import SwiftUI

struct LightPlacementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presenter: LightPlacementPresenter

    init(presenter: LightPlacementPresenter) {
        _presenter = StateObject(wrappedValue: presenter)
    }

    var body: some View {
        StudioCameraLayout(
            backAction: { dismiss() },
            canvas: {
                ZStack {
                    ARViewContainer(
                        sessionService: presenter.arService,
                        content: ARSceneContent(
                            subject: presenter.entity.subject,
                            lights: presenter.entity.lights,
                            selectedLightID: presenter.entity.selectedLightID,
                            placementPreview: presenter.entity.placementPreview,
                            showAnchors: false,
                            // Placement only records the fixture coordinate. The
                            // editable beam/aim visualization belongs in Editor.
                            showLightDirection: false
                        )
                    )
                    CameraCrosshair()
                }
            },
            inspector: { controls }
        )
        .alert("Light setup", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { presenter.errorMessage = nil }
        } message: {
            Text(presenter.errorMessage ?? "")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioGuideHeader(
                step: "Step 2 of 3",
                title: "Place the lamps",
                detail: "Arahkan reticle ke lantai di bawah lampu. Power, warna, beam, dan tinggi diatur nanti di editor."
            )

            Divider().overlay(AppTheme.border)

            if !presenter.entity.lights.isEmpty {
                LightSelector(
                    lights: presenter.entity.lights,
                    selectedID: presenter.entity.selectedLightID,
                    select: presenter.selectLight
                )
            }

            Label(
                placementStatus,
                systemImage: presenter.entity.lights.isEmpty
                    ? "scope" : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(
                presenter.entity.lights.isEmpty
                    ? AppTheme.textSecondary : AppTheme.primaryBright
            )

            Spacer()

            if presenter.entity.selectedLight != nil {
                HStack(spacing: 8) {
                    Button(action: presenter.moveLight) {
                        Label("Move Selected", systemImage: "move.3d")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())

                    Button(role: .destructive, action: presenter.removeLight) {
                        Image(systemName: "trash")
                            .accessibilityLabel("Remove selected lamp")
                    }
                    .buttonStyle(StudioIconButtonStyle(tint: AppTheme.destructive))
                }
            }

            if presenter.entity.canAddLight {
                Button(action: presenter.placeLight) {
                    Label(
                        "Place Lamp \(presenter.entity.lights.count + 1)",
                        systemImage: "plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioPrimaryButtonStyle(tint: AppTheme.placement))
                .disabled(presenter.entity.placementPreview == nil)
                .opacity(presenter.entity.placementPreview == nil ? 0.38 : 1)
            }

            Button(action: presenter.continueToCapture) {
                Label("Continue to Camera", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioPrimaryButtonStyle())
            .disabled(!presenter.entity.isReadyForPreview)
            .opacity(presenter.entity.isReadyForPreview ? 1 : 0.38)
        }
        .padding(18)
    }

    private var placementStatus: String {
        switch presenter.entity.lights.count {
        case 0: "Belum ada posisi lampu"
        case 1: "1 posisi lampu tersimpan"
        default: "\(presenter.entity.lights.count) posisi lampu tersimpan"
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { presenter.errorMessage != nil },
            set: { if !$0 { presenter.errorMessage = nil } }
        )
    }
}
