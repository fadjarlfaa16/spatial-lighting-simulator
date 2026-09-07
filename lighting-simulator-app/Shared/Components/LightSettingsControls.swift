import SwiftUI

struct LightSettingsControls: View {
    let light: VirtualLight
    let heightChanged: (Float) -> Void
    let intensityChanged: (Float) -> Void
    let kelvinChanged: (Float) -> Void
    let beamChanged: (Float) -> Void
    let enabledChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 7) {
            settingRow("Height", value: light.height, range: 0.2...5, step: 0.1, valueText: String(format: "%.1f m", light.height), action: heightChanged)
            settingRow("Intensity", value: light.intensity, range: 0...100, step: 1, valueText: "\(Int(light.intensity))%", action: intensityChanged)
            kelvinRow
            settingRow("Beam", value: light.beamAngle, range: 10...120, step: 1, valueText: "\(Int(light.beamAngle))°", action: beamChanged)
            Toggle("Light enabled", isOn: Binding(get: { light.enabled }, set: enabledChanged))
                .font(.caption)
        }
    }

    private var kelvinRow: some View {
        let rgb = SpatialMath.kelvinToRGB(light.kelvin)
        let currentColor = Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
        return VStack(spacing: 3) {
            HStack {
                Text("Kelvin")
                Circle().fill(currentColor).frame(width: 12, height: 12)
                Spacer()
                Text("\(Int(light.kelvin)) K").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 1, green: 0.38, blue: 0.08),
                        Color(red: 1, green: 0.82, blue: 0.50),
                        .white,
                        Color(red: 0.55, green: 0.72, blue: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 5)
                .clipShape(Capsule())
                Slider(
                    value: Binding(get: { light.kelvin }, set: kelvinChanged),
                    in: 2_700...10_000,
                    step: 100
                )
                .tint(currentColor)
            }
        }
    }

    private func settingRow(
        _ title: String,
        value: Float,
        range: ClosedRange<Float>,
        step: Float,
        valueText: String,
        action: @escaping (Float) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: Binding(get: { value }, set: action), in: range, step: step)
                .tint(.orange)
        }
    }
}
