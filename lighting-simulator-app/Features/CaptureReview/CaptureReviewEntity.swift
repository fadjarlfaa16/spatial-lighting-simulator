import CoreGraphics
import Foundation

struct CapturedPhotoDraft: @unchecked Sendable {
    let data: Data
    let preview: CGImage
    let cameraTransform: SpatialTransform
    let cameraCalibration: CameraCalibration
}

struct CaptureReviewEntity {
    var draft: CapturedPhotoDraft?
    var phase: AnalysisPhase = .idle
    var canCapture = true
}
