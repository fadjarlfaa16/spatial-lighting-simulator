import Foundation
import SwiftUI

struct LightSelector: View {
  let lights: [VirtualLight]
  let selectedID: UUID?
  let select: (UUID) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(lights.enumerated()), id: \.element.id) { index, light in
        Button {
          select(light.id)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "lightbulb.max.fill")
              .font(.caption)
            Text("L\(index + 1)")
              .font(.caption.weight(.semibold))
            Text(light.name.replacingOccurrences(of: " Light", with: ""))
              .font(.caption2)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity)
          .frame(height: 38)
          .padding(.horizontal, 8)
          .foregroundStyle(
            selectedID == light.id ? AppTheme.placement : AppTheme.textSecondary
          )
          .background(
            selectedID == light.id
              ? AppTheme.placement.opacity(0.14) : AppTheme.surfaceRaised,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .stroke(
                selectedID == light.id
                  ? AppTheme.placement.opacity(0.75) : AppTheme.border
              )
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(light.name)")
      }
    }
  }
}

struct LightMeasurementCard: View {
  let measurement: LightMeasurement

  var body: some View {
    Grid(horizontalSpacing: 12, verticalSpacing: 4) {
      GridRow {
        value("Distance", String(format: "%.2f m", measurement.distance))
        value("Est. center", luxText)
      }
      GridRow {
        value("Beam Ø", String(format: "%.2f m", measurement.beamDiameter))
        value("Elevation", String(format: "%.1f°", measurement.elevationDegrees))
      }
      GridRow {
        value("Incidence", String(format: "%.0f%%", measurement.incidence * 100))
        value("Fixture output", String(format: "%.0f%%", measurement.fixtureOutputMultiplier * 100))
      }
    }
    .padding(10)
    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
  }

  private func value(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.caption.monospacedDigit().bold())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var luxText: String {
    if measurement.estimatedCenterLux >= 1_000 {
      return String(format: "%.1f klx", measurement.estimatedCenterLux / 1_000)
    }
    return String(format: "%.0f lux", measurement.estimatedCenterLux)
  }
}

struct AimAdjustmentControls: View {
  let light: VirtualLight
  let adjust: (_ panDelta: Float, _ tiltDelta: Float) -> Void

  var body: some View {
    VStack(spacing: 5) {
      HStack {
        Text("Manual head angle").font(.caption)
        Spacer()
        Text(String(format: "Pan %+.0f° · Tilt %+.0f°", light.panOffset, light.tiltOffset))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        aimButton("arrow.left", pan: -5, tilt: 0, label: "Pan left")
        aimButton("arrow.right", pan: 5, tilt: 0, label: "Pan right")
        aimButton("arrow.up", pan: 0, tilt: 5, label: "Tilt up")
        aimButton("arrow.down", pan: 0, tilt: -5, label: "Tilt down")
      }
    }
  }

  private func aimButton(_ icon: String, pan: Float, tilt: Float, label: String) -> some View {
    Button {
      adjust(pan, tilt)
    } label: {
      Image(systemName: icon).frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .accessibilityLabel(label)
  }
}
