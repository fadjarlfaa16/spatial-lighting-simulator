import SwiftUI

struct CameraCrosshair: View {
  var body: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: 34, height: 34)
      Rectangle().fill(.white).frame(width: 12, height: 1)
      Rectangle().fill(.white).frame(width: 1, height: 12)
    }
    .shadow(radius: 2)
    .allowsHitTesting(false)
  }
}

struct InstructionCard: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.headline)
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }
}

struct SpatialDebugSnapshot: Equatable {
  var tracking: String
  var camera: SpatialVector?
  var subject: SpatialVector?
  var light: SpatialVector?
  var cameraToSubject: Float?
  var lightToSubject: Float?
  var capabilities: ARCapabilities
  var lightCount: Int = 0
}

struct SpatialDebugOverlay: View {
  let snapshot: SpatialDebugSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("SPATIAL DEBUG").font(.caption2.bold()).foregroundStyle(.orange)
      row("Tracking", snapshot.tracking)
      row("Camera", snapshot.camera?.coordinateText ?? "—")
      row("Subject", snapshot.subject?.coordinateText ?? "—")
      row("Light", snapshot.light?.coordinateText ?? "—")
      row("Placed lights", "\(snapshot.lightCount) / 3")
      row("Camera → Subject", snapshot.cameraToSubject?.meterText ?? "—")
      row("Light → Subject", snapshot.lightToSubject?.meterText ?? "—")
      Divider().overlay(.white.opacity(0.2))
      row("Tracking mode", "Raycast only · no LiDAR")
    }
    .font(.system(.caption2, design: .monospaced))
    .padding(10)
    .foregroundStyle(.white)
    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
  }

  private func row(_ name: String, _ value: String) -> some View {
    HStack(spacing: 8) {
      Text(name).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value).multilineTextAlignment(.trailing)
    }
  }

  private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }
}

extension SpatialVector {
  var coordinateText: String { String(format: "%.2f, %.2f, %.2f", x, y, z) }
}

extension Float {
  var meterText: String { String(format: "%.2f m", self) }
}
