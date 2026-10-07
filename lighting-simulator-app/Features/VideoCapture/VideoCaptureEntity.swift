import Foundation

enum VideoCapturePhase: Equatable {
  case idle
  case preparingCamera
  case ready
  case recording
  case processing(VideoRelightingProgress)
  case completed
  case failed(String)

  var message: String {
    switch self {
    case .idle: return "Preparing video capture…"
    case .preparingCamera: return "Preparing the 720p camera…"
    case .ready: return "Ready to record at 720p · 30 fps"
    case .recording: return "Recording normal video…"
    case .processing(let progress):
      return "Relighting frame \(progress.processedFrames) of \(progress.estimatedFrameCount)…"
    case .completed: return "The original and relit videos are ready."
    case .failed(let message): return message
    }
  }

  var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }
}

enum VideoSaveStatus: Equatable {
  case idle
  case saving
  case saved
}

struct VideoCaptureEntity: Equatable {
  var phase: VideoCapturePhase = .idle
  var isRecording = false
  var originalVideoURL: URL?
  var relitVideoURL: URL?
  var originalSaveStatus: VideoSaveStatus = .idle
  var relitSaveStatus: VideoSaveStatus = .idle

  var progressFraction: Double? {
    if case .processing(let progress) = phase { return progress.fraction }
    return nil
  }


  var cameraShouldBeActive: Bool {
    switch phase {
    case .idle, .preparingCamera, .ready, .recording: true
    case .processing, .completed, .failed: false
    }
  }
}
