import SwiftUI

struct VideoCaptureView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var presenter: VideoCapturePresenter
  @ObservedObject private var recorder: VideoRecordingService

  init(presenter: VideoCapturePresenter) {
    _presenter = StateObject(wrappedValue: presenter)
    _recorder = ObservedObject(wrappedValue: presenter.recorder)
  }

  var body: some View {
    StudioCameraLayout(
      backAction: {
        guard !presenter.entity.isRecording, !presenter.entity.phase.isProcessing else { return }
        presenter.stop()
        dismiss()
      },
      canvas: {
        ZStack {
          if presenter.entity.cameraShouldBeActive {
            VideoCapturePreview(
              session: recorder.session,
              cameraPosition: recorder.cameraPosition
            )
          } else {
            AppTheme.backgroundBottom
            VStack(spacing: 14) {
              if presenter.entity.phase.isProcessing {
                ProgressView()
                  .controlSize(.large)
                  .tint(AppTheme.primaryBright)
              } else {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 42))
                  .foregroundStyle(AppTheme.primaryBright)
              }
              Text(presenter.entity.phase.isProcessing ? "Processing video…" : "Video ready")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            }
          }
        }
      },
      inspector: { inspector }
    )
    .task { await presenter.start() }
    .onDisappear { presenter.stop() }
    .alert("Video Recording", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) { presenter.errorMessage = nil }
    } message: {
      Text(presenter.errorMessage ?? "")
    }
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 14) {
      StudioGuideHeader(
        step: "Video",
        title: presenter.entity.phase == .completed ? "Video complete" : "Record the scene",
        detail: "The camera records an untouched 720p, 30 fps video. The approved lighting plan will be applied after recording."
      )
      Divider().overlay(AppTheme.border)
      if let progress = presenter.entity.progressFraction {
        ProgressView(value: progress)
          .tint(AppTheme.primaryBright)
      }
      Label(presenter.entity.phase.message, systemImage: phaseIcon)
        .font(.caption)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer()
      switch presenter.entity.phase {
      case .completed:
        VStack(spacing: 10) {
          Button(action: presenter.saveOriginalVideo) {
            saveButtonLabel(
              title: "Save Original Video",
              status: presenter.entity.originalSaveStatus
            )
          }
          .buttonStyle(StudioSecondaryButtonStyle())
          .disabled(
            presenter.entity.originalVideoURL == nil
              || presenter.entity.originalSaveStatus == .saving
          )

          Button(action: presenter.saveRelitVideo) {
            saveButtonLabel(
              title: "Save Relit Video",
              status: presenter.entity.relitSaveStatus
            )
          }
          .buttonStyle(StudioPrimaryButtonStyle())
          .disabled(
            presenter.entity.relitVideoURL == nil
              || presenter.entity.relitSaveStatus == .saving
          )

          Button("Back to Projects", action: presenter.done)
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
        }
      case .processing:
        VStack(spacing: 10) {
          ProgressView().controlSize(.large)
          Text("Keep the app open while each frame is analyzed and relit.")
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
      case .preparingCamera, .idle:
        ProgressView().frame(maxWidth: .infinity)
      default:
        HStack(spacing: 12) {
          Button(action: presenter.toggleRecording) {
            Label(
              presenter.entity.isRecording ? "Stop Recording" : "Start Recording",
              systemImage: presenter.entity.isRecording ? "stop.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(StudioPrimaryButtonStyle())
          .disabled(ifRecordingUnavailable)

          if !presenter.entity.isRecording {
            Button(action: presenter.toggleCamera) {
              Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title3)
                .frame(width: 44, height: 44)
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .disabled(ifRecordingUnavailable)
          }
        }
      }
    }
    .padding(18)
  }

  @ViewBuilder
  private func saveButtonLabel(title: String, status: VideoSaveStatus) -> some View {
    HStack(spacing: 10) {
      if status == .saving {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: status == .saved ? "checkmark.circle.fill" : "square.and.arrow.down")
      }
      Text(status == .saved ? "Saved" : title)
    }
    .frame(maxWidth: .infinity)
  }

  private var ifRecordingUnavailable: Bool {
    if case .ready = presenter.entity.phase { return false }
    return !presenter.entity.isRecording
  }

  private var phaseIcon: String {
    switch presenter.entity.phase {
    case .recording: "record.circle.fill"
    case .processing: "wand.and.stars"
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle"
    default: "video"
    }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { presenter.errorMessage != nil },
      set: { if !$0 { presenter.errorMessage = nil } }
    )
  }
}
