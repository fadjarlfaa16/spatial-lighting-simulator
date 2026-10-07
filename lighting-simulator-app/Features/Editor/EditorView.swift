import SwiftUI
import UIKit

struct EditorView: View {
    @StateObject private var presenter: EditorPresenter
    @State private var previousDrag = CGSize.zero

    init(presenter: EditorPresenter) {
        _presenter = StateObject(wrappedValue: presenter)
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    imageWorkspace
                        .frame(width: proxy.size.width * 0.665)
                    Divider()
                    inspector
                        .frame(width: proxy.size.width * 0.335)
                }
            }
            .disabled(presenter.entity.isExporting)
            .scaleEffect(presenter.entity.isExporting ? 0.992 : 1)
            .offset(y: presenter.entity.isExporting ? 4 : 0)
            .saturation(presenter.entity.isExporting ? 0.86 : 1)

            if presenter.entity.isExporting {
                exportProgressOverlay
            }
        }
        .background(AppTheme.backgroundBottom)
        .animation(.easeOut(duration: 0.18), value: presenter.entity.isExporting)
        .navigationBarBackButtonHidden()
        .task { await presenter.start() }
        .alert("Lighting Studio", isPresented: messageIsPresented) {
            Button("OK", role: .cancel) { presenter.message = nil }
        } message: { Text(presenter.message ?? "") }
    }

    private var imageWorkspace: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: presenter.done) { Label("Projects", systemImage: "chevron.left") }
                Spacer()
                Picker("View", selection: displayBinding) {
                    ForEach(EditorDisplayMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer()
                Button(action: presenter.preview) {
                    Image(systemName: presenter.entity.isCleanPreview ? "scope" : "eye")
                }
                .buttonStyle(StudioIconButtonStyle(tint: AppTheme.primaryBright))
                .accessibilityLabel(
                    presenter.entity.isCleanPreview ? "Show light aim" : "Clean preview"
                )
                Button(action: presenter.export) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(StudioIconButtonStyle(tint: AppTheme.primaryBright))
                .accessibilityLabel("Export")
                .disabled(presenter.entity.resources == nil || presenter.entity.isExporting)
                if presenter.entity.mediaKind == .video {
                    Button(action: presenter.recordVideo) {
                        Image(systemName: "video.fill")
                    }
                    .buttonStyle(StudioIconButtonStyle(tint: AppTheme.placement))
                    .accessibilityLabel("Record relit video")
                    .disabled(presenter.entity.resources == nil || presenter.entity.isExporting)
                }
            }.padding(.horizontal)

            ZStack {
                displaySurface
                if presenter.entity.displayMode == .relit,
                   !presenter.entity.isCleanPreview,
                   let light = selectedRenderLight {
                    GeometryReader { proxy in
                        COBAimOverlay(light: light)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let delta = CGSize(
                                    width: value.translation.width - previousDrag.width,
                                    height: value.translation.height - previousDrag.height
                                )
                                previousDrag = value.translation
                                presenter.aim(translation: delta)
                            }
                            .onEnded { _ in previousDrag = .zero })
                    }
                }
                if presenter.entity.phase != .completed {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(presenter.entity.phase.message)
                    }.padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .aspectRatio(imageAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding([.horizontal, .bottom])
        }
    }

    @ViewBuilder private var displaySurface: some View {
        switch presenter.entity.displayMode {
        case .relit:
            if let resources = presenter.entity.resources {
                MetalRelightingPreview(
                    resources: resources,
                    parameters: presenter.entity.parameters,
                    onFrame: { _ in },
                    onError: { presenter.message = $0 }
                )
            } else { cgImage(presenter.entity.photo) }
        case .original: cgImage(presenter.entity.photo)
        case .normal: cgImage(presenter.entity.normalVisualization)
        case .mask: cgImage(presenter.entity.maskVisualization)
        }
    }

    private var inspector: some View {
        VStack(spacing: 10) {
            if let plan = presenter.entity.plan {
                FloorPlanPreview(plan: plan, selectedLightID: presenter.entity.selectedLightID)
                    .frame(maxHeight: 210)
                    .padding([.horizontal, .top])
                Text(spatialSummary(plan))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("LIGHTING PLAN").font(.caption.bold()).foregroundStyle(.secondary)
                    lightPicker
                    if let light = presenter.entity.selectedWorldLight {
                        lightTypePicker(light)
                        Text("Drag on the photo to aim \(light.name). Use the pad to move its floor position.")
                            .font(.caption).foregroundStyle(.secondary)
                        LightPositionPad(
                            floorDistance: selectedFloorDistance,
                            onMove: presenter.move
                        )
                        editorSlider("Power", value: light.intensity, range: 0...100, unit: "%", presenter.intensity)
                        editorSlider("Height", value: light.height, range: 0.2...5, unit: "m", presenter.height)
                        editorSlider("Beam", value: light.beamAngle, range: 10...120, unit: "°", presenter.beam)
                        if light.effectiveCOBType == .classic {
                            editorSlider("Kelvin", value: light.kelvin, range: 2_700...10_000, unit: "K", presenter.kelvin)
                        } else {
                            ColorPicker(
                                "Emitter Color",
                                selection: rgbColorBinding(light),
                                supportsOpacity: false
                            )
                            .accessibilityHint("Choose the RGB COB emitter color")
                        }
                        if let render = selectedRenderLight {
                            editorSlider("Feather", value: render.falloffSoftness, range: 0.02...1, unit: "", presenter.falloff)
                            Text(String(format: "COB head → target %.2f m", render.distanceMeters))
                                .font(.caption.monospacedDigit()).foregroundStyle(.cyan)
                        }
                    }
                    Divider()
                    editorSlider("Ambient", value: presenter.entity.parameters.ambientIntensity, range: 0...1.5, unit: "", presenter.ambient)
                    editorSlider("Diffuse", value: presenter.entity.parameters.diffuseStrength, range: 0...2, unit: "", presenter.diffuse)
                    editorSlider("Haze", value: presenter.entity.parameters.hazeIntensity, range: 0...1, unit: "", presenter.haze)
                    DisclosureGroup("Advanced material") {
                        VStack {
                            editorSlider("Specular", value: presenter.entity.parameters.specularStrength, range: 0...0.5, unit: "", presenter.specular)
                            editorSlider("Shininess", value: presenter.entity.parameters.specularShininess, range: 4...256, unit: "", presenter.shininess)
                        }
                    }
                    if let summary = presenter.entity.inferenceSummary {
                        Text("Normal: \(summary)").font(.caption).foregroundStyle(.secondary)
                    }
                    if presenter.entity.mediaKind == .video {
                        Divider()
                        Button(action: presenter.recordVideo) {
                            Label("Record 720p Video", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(StudioPrimaryButtonStyle())
                        .disabled(presenter.entity.resources == nil || presenter.entity.isExporting)
                    }
                }.padding()
            }
        }.background(AppTheme.surface)
    }

    private var exportProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.primaryBright)
                Text("Exporting full-resolution image…")
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Refining edges with the original photo. Please keep the app open.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.border))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exporting full-resolution image")
        .transition(.opacity)
        .zIndex(10)
    }

    private var lightPicker: some View {
        Picker("Lamp", selection: lightSelectionBinding) {
            ForEach(presenter.entity.plan?.lights ?? []) { Text($0.name).tag(Optional($0.id)) }
        }.pickerStyle(.segmented)
    }

    private func lightTypePicker(_ light: VirtualLight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COB TYPE")
                .font(.caption2.bold())
                .foregroundStyle(AppTheme.textSecondary)
            Picker("COB Type", selection: Binding(
                get: { light.effectiveCOBType },
                set: presenter.lightType
            )) {
                ForEach(COBLightType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func rgbColorBinding(_ light: VirtualLight) -> Binding<Color> {
        Binding(
            get: {
                let color = light.effectiveRGBColor
                return Color(
                    red: Double(color.red),
                    green: Double(color.green),
                    blue: Double(color.blue)
                )
            },
            set: { value in
                let uiColor = UIColor(value)
                var red: CGFloat = 1
                var green: CGFloat = 1
                var blue: CGFloat = 1
                var alpha: CGFloat = 1
                guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                    return
                }
                presenter.rgbColor(LightRGBColor(
                    red: Float(red),
                    green: Float(green),
                    blue: Float(blue)
                ))
            }
        )
    }

    private func editorSlider(
        _ title: String, value: Float, range: ClosedRange<Float>, unit: String,
        _ update: @escaping (Float) -> Void
    ) -> some View {
        VStack(spacing: 5) {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f%@", value, unit)).monospacedDigit() }
            Slider(value: Binding(get: { value }, set: update), in: range)
        }
    }

    @ViewBuilder private func cgImage(_ image: CGImage?) -> some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Not available", systemImage: "photo")
        }
    }

    private var selectedRenderLight: RelightLight? {
        presenter.entity.parameters.lights.first { $0.id == presenter.entity.selectedLightID }
    }
    private var selectedFloorDistance: Float {
        guard let plan = presenter.entity.plan,
              let light = presenter.entity.selectedWorldLight else { return 0 }
        return SpatialMath.horizontalDistance(
            light.position.simd,
            plan.subjectPosition.simd
        )
    }
    private func spatialSummary(_ plan: SpatialPlanSnapshot) -> String {
        let cameraRange = SpatialMath.horizontalDistance(
            plan.cameraTransform.position.simd,
            plan.subjectPosition.simd
        )
        guard let light = presenter.entity.selectedWorldLight else {
            return String(format: "CAM → SUBJ %.2f m", cameraRange)
        }
        let floorRange = SpatialMath.horizontalDistance(
            light.position.simd,
            plan.subjectPosition.simd
        )
        let elevation = SpatialMath.measurement(for: light)?.elevationDegrees ?? 0
        return String(
            format: "CAM → SUBJ %.2f m   ·   LAMP → SUBJ %.2f m   ·   elev. %.1f°",
            cameraRange,
            floorRange,
            elevation
        )
    }
    private var imageAspect: CGFloat {
        guard let image = presenter.entity.photo, image.height > 0 else { return 4 / 3 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
    private var displayBinding: Binding<EditorDisplayMode> {
        Binding(get: { presenter.entity.displayMode }, set: presenter.display)
    }
    private var lightSelectionBinding: Binding<UUID?> {
        Binding(get: { presenter.entity.selectedLightID }, set: { if let id = $0 { presenter.selectLight(id) } })
    }
    private var messageIsPresented: Binding<Bool> {
        Binding(get: { presenter.message != nil }, set: { if !$0 { presenter.message = nil } })
    }
}

/// Compact editor-only X/Z control. It deliberately emits discrete intents;
/// the interactor owns coordinate conversion, limits, rendering, and persistence.
private struct LightPositionPad: View {
    let floorDistance: Float
    let onMove: (LightPlanarMoveDirection) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Move position", systemImage: "move.3d")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Camera-relative · X/Z plane")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                Text(String(format: "%.2f m from subject · max %.0f m", floorDistance,
                            SpatialMath.editorLightMaximumFloorDistance))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.primaryBright)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    padPlaceholder
                    directionButton("arrow.up", .forward, "Move light forward by 10 centimeters")
                    padPlaceholder
                }
                GridRow {
                    directionButton("arrow.left", .left, "Move light left by 10 centimeters")
                    Text("10\ncm")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.backgroundBottom.opacity(0.72), in: Circle())
                    directionButton("arrow.right", .right, "Move light right by 10 centimeters")
                }
                GridRow {
                    padPlaceholder
                    directionButton("arrow.down", .backward, "Move light backward by 10 centimeters")
                    padPlaceholder
                }
            }
        }
        .padding(10)
        .background(AppTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(AppTheme.border))
        .accessibilityElement(children: .contain)
    }

    private var padPlaceholder: some View {
        Color.clear.frame(width: 34, height: 34)
    }

    private func directionButton(
        _ systemName: String,
        _ direction: LightPlanarMoveDirection,
        _ accessibilityLabel: String
    ) -> some View {
        Button { onMove(direction) } label: {
            Image(systemName: systemName)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(LightPositionStepButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct LightPositionStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(AppTheme.placement)
            .background(
                AppTheme.placement.opacity(configuration.isPressed ? 0.28 : 0.12),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.placement.opacity(0.24)))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

/// Image-space representation of the selected physical COB fixture. The base
/// location begins at its AR placement, then follows editor X/Z steps while its
/// head direction follows image dragging. A source outside the field can be clipped to the photo
/// edge, but a source physically behind the camera has no valid image-space
/// origin and is represented by its aim reticle only.
private struct COBAimOverlay: View {
    let light: RelightLight

    var body: some View {
        Canvas { context, size in
            let fixtureColor = Color(
                red: Double(min(max(light.color.x, 0), 1)),
                green: Double(min(max(light.color.y, 0), 1)),
                blue: Double(min(max(light.color.z, 0), 1))
            )
            let target = CGPoint(
                x: CGFloat(light.normalizedPosition.x) * size.width,
                y: CGFloat(light.normalizedPosition.y) * size.height
            )
            let reticleRadius: CGFloat = 8
            let reticle = CGRect(
                x: target.x - reticleRadius,
                y: target.y - reticleRadius,
                width: reticleRadius * 2,
                height: reticleRadius * 2
            )

            // A fixture behind the capture camera cannot be projected into the
            // photo. Keep aiming interactive, but do not invent a COB icon or a
            // cone from an arbitrary clamped screen edge.
            guard light.sourceIsProjectable else {
                context.stroke(
                    Path(ellipseIn: reticle),
                    with: .color(fixtureColor.opacity(0.70)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                return
            }
            let rawSource = CGPoint(
                x: CGFloat(light.normalizedSourcePosition.x) * size.width,
                y: CGFloat(light.normalizedSourcePosition.y) * size.height
            )
            let source = CGPoint(
                x: min(max(rawSource.x, 24), size.width - 24),
                y: min(max(rawSource.y, 24), size.height - 24)
            )
            let delta = CGVector(dx: target.x - source.x, dy: target.y - source.y)
            let length = max(hypot(delta.dx, delta.dy), 1)
            let direction = CGVector(dx: delta.dx / length, dy: delta.dy / length)
            let perpendicular = CGVector(dx: -direction.dy, dy: direction.dx)
            let halfWidth = min(
                CGFloat(light.radius) * min(size.width, size.height),
                min(size.width, size.height) * 0.7
            )
            let left = CGPoint(
                x: target.x + perpendicular.dx * halfWidth,
                y: target.y + perpendicular.dy * halfWidth
            )
            let right = CGPoint(
                x: target.x - perpendicular.dx * halfWidth,
                y: target.y - perpendicular.dy * halfWidth
            )

            // A very light volumetric cone gives the fixture an AR-style depth
            // cue without covering the photograph being evaluated.
            var cone = Path()
            cone.move(to: source)
            cone.addLine(to: left)
            cone.addLine(to: right)
            cone.closeSubpath()
            context.fill(
                cone,
                with: .linearGradient(
                    Gradient(colors: [
                        fixtureColor.opacity(0.12),
                        fixtureColor.opacity(0.045),
                        fixtureColor.opacity(0.008),
                    ]),
                    startPoint: source,
                    endPoint: target
                )
            )

            let innerHalfWidth = halfWidth * 0.38
            let innerLeft = CGPoint(
                x: target.x + perpendicular.dx * innerHalfWidth,
                y: target.y + perpendicular.dy * innerHalfWidth
            )
            let innerRight = CGPoint(
                x: target.x - perpendicular.dx * innerHalfWidth,
                y: target.y - perpendicular.dy * innerHalfWidth
            )
            var core = Path()
            core.move(to: source)
            core.addLine(to: innerLeft)
            core.addLine(to: innerRight)
            core.closeSubpath()
            context.fill(
                core,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.09),
                        fixtureColor.opacity(0.025),
                        Color.clear,
                    ]),
                    startPoint: source,
                    endPoint: target
                )
            )

            var coneEdges = Path()
            coneEdges.move(to: source)
            coneEdges.addLine(to: left)
            coneEdges.move(to: source)
            coneEdges.addLine(to: right)
            context.stroke(
                coneEdges,
                with: .color(fixtureColor.opacity(0.32)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 7])
            )

            var axis = Path()
            axis.move(to: source)
            axis.addLine(to: target)
            context.stroke(
                axis,
                with: .color(fixtureColor.opacity(0.72)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [9, 6])
            )

            // A small projected COB head: offset back/front faces and connecting
            // edges make it read as a translucent 3D fixture, not a flat icon.
            let backCenter = CGPoint(
                x: source.x - direction.dx * 22,
                y: source.y - direction.dy * 22
            )
            let frontCenter = CGPoint(
                x: source.x + direction.dx * 6,
                y: source.y + direction.dy * 6
            )
            let fixtureHalfWidth: CGFloat = 9
            let backLeft = CGPoint(
                x: backCenter.x + perpendicular.dx * fixtureHalfWidth,
                y: backCenter.y + perpendicular.dy * fixtureHalfWidth
            )
            let backRight = CGPoint(
                x: backCenter.x - perpendicular.dx * fixtureHalfWidth,
                y: backCenter.y - perpendicular.dy * fixtureHalfWidth
            )
            let frontLeft = CGPoint(
                x: frontCenter.x + perpendicular.dx * fixtureHalfWidth,
                y: frontCenter.y + perpendicular.dy * fixtureHalfWidth
            )
            let frontRight = CGPoint(
                x: frontCenter.x - perpendicular.dx * fixtureHalfWidth,
                y: frontCenter.y - perpendicular.dy * fixtureHalfWidth
            )
            var fixtureBody = Path()
            fixtureBody.move(to: backLeft)
            fixtureBody.addLine(to: frontLeft)
            fixtureBody.addLine(to: frontRight)
            fixtureBody.addLine(to: backRight)
            fixtureBody.closeSubpath()
            context.fill(
                fixtureBody,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.black.opacity(0.58),
                        fixtureColor.opacity(0.42),
                    ]),
                    startPoint: backCenter,
                    endPoint: frontCenter
                )
            )
            context.stroke(
                fixtureBody,
                with: .color(.white.opacity(0.58)),
                lineWidth: 1
            )

            let lens = CGRect(
                x: frontCenter.x - 7,
                y: frontCenter.y - 7,
                width: 14,
                height: 14
            )
            context.fill(
                Path(ellipseIn: lens),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.90), fixtureColor.opacity(0.55)]),
                    center: frontCenter,
                    startRadius: 1,
                    endRadius: 9
                )
            )
            context.stroke(
                Path(ellipseIn: lens),
                with: .color(.white.opacity(0.78)),
                lineWidth: 1
            )

            context.stroke(
                Path(ellipseIn: reticle),
                with: .color(fixtureColor.opacity(0.70)),
                style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
            )
        }
        .opacity(0.88)
        .accessibilityHidden(true)
    }
}
