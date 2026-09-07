import CoreGraphics
import Foundation
import simd

nonisolated struct ImageLetterboxTransform: Sendable, Equatable {
    let sourceWidth: Int
    let sourceHeight: Int
    let modelWidth: Int
    let modelHeight: Int
    let contentWidth: Int
    let contentHeight: Int
    let paddingLeft: Int
    let paddingRight: Int
    let paddingTop: Int
    let paddingBottom: Int
    let scale: Float
}

nonisolated struct NormalBuffer: Sendable {
    let width: Int
    let height: Int
    /// Unit surface vectors in the Sapiens camera convention. Invalid samples are zero.
    let normals: [SIMD3<Float>]
}

nonisolated struct ForegroundMaskBuffer: Sendable {
    let width: Int
    let height: Int
    /// Soft coverage in 0...255. Vision creates this once per proceeded photo.
    let coverage: [UInt8]
}

nonisolated enum ComputePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case cpuAndGPU
    case cpuOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .cpuAndGPU: "GPU + CPU"
        case .cpuOnly: "CPU"
        }
    }
}

nonisolated enum AnalysisPhase: Sendable, Equatable {
    case idle
    case capturing
    case compressing
    case masking
    case preprocessing
    case estimatingNormals
    case preparingGPU
    case completed
    case failed(String)

    var message: String {
        switch self {
        case .idle: "Siap"
        case .capturing: "Mengambil foto kualitas tinggi…"
        case .compressing: "Mengoptimalkan foto…"
        case .masking: "Membuat foreground mask…"
        case .preprocessing: "Menyiapkan input Sapiens Normal…"
        case .estimatingNormals: "Menganalisis surface normal…"
        case .preparingGPU: "Menyiapkan editor Metal…"
        case .completed: "Selesai"
        case .failed(let message): message
        }
    }
}

nonisolated struct NormalAnalysisResult: Sendable {
    let originalImage: CGImage
    let normals: NormalBuffer
    let foregroundMask: ForegroundMaskBuffer?
    let normalVisualization: CGImage
    let inferenceDuration: Duration
    let computeUnits: String
}

nonisolated protocol NormalEstimating: Sendable {
    func estimate(
        image: CGImage,
        computePreference: ComputePreference,
        progress: @escaping @Sendable (AnalysisPhase) async -> Void
    ) async throws -> NormalAnalysisResult
}
