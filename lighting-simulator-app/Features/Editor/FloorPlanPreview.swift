import SwiftUI
import simd

struct FloorPlanPreview: View {
    let plan: SpatialPlanSnapshot
    let selectedLightID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let points = [plan.cameraTransform.position.simd, plan.subjectPosition.simd]
                + plan.lights.flatMap { light in
                    [light.position.simd, SpatialMath.aimedPoint(for: light) ?? plan.subjectPosition.simd]
                }
            let projection = PlanProjection(
                points: points,
                anchor: plan.subjectPosition.simd,
                size: proxy.size
            )

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.045))

                Canvas { context, _ in
                    drawGrid(&context, projection: projection)

                    let camera = projection.map(plan.cameraTransform.position.simd)
                    let subject = projection.map(plan.subjectPosition.simd)
                    drawCamera(&context, projection: projection)
                    drawMarker(&context, point: camera, color: .cyan, label: "CAM")
                    drawMarker(&context, point: subject, color: .white, label: "SUBJ")

                    for (index, light) in plan.lights.enumerated() {
                        let source = projection.map(light.position.simd)
                        let targetWorld = SpatialMath.aimedPoint(for: light) ?? plan.subjectPosition.simd
                        let target = projection.map(targetWorld)
                        let selected = light.id == selectedLightID

                        var ray = Path()
                        ray.move(to: source)
                        ray.addLine(to: target)
                        context.stroke(
                            ray,
                            with: .color(selected ? .orange : .yellow.opacity(0.38)),
                            style: StrokeStyle(
                                lineWidth: selected ? 2.5 : 1,
                                lineCap: .round,
                                dash: selected ? [] : [5, 4]
                            )
                        )
                        drawMarker(
                            &context,
                            point: source,
                            color: selected ? .orange : .yellow,
                            label: "L\(index + 1)"
                        )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.12), value: plan.lights)
        }
        .accessibilityLabel("Denah kartesius posisi kamera, subjek, dan lampu")
    }

    private func drawGrid(
        _ context: inout GraphicsContext,
        projection: PlanProjection
    ) {
        let spacing: Float = projection.worldSpan <= 5 ? 0.5 : 1
        var minor = Path()
        var major = Path()

        var x = floor(projection.minimumX / spacing) * spacing
        while x <= projection.maximumX + 0.001 {
            let top = projection.map(SIMD3(x, 0, projection.minimumZ))
            let bottom = projection.map(SIMD3(x, 0, projection.maximumZ))
            if abs(x) < spacing * 0.1 {
                major.move(to: top); major.addLine(to: bottom)
            } else {
                minor.move(to: top); minor.addLine(to: bottom)
            }
            x += spacing
        }

        var z = floor(projection.minimumZ / spacing) * spacing
        while z <= projection.maximumZ + 0.001 {
            let left = projection.map(SIMD3(projection.minimumX, 0, z))
            let right = projection.map(SIMD3(projection.maximumX, 0, z))
            if abs(z) < spacing * 0.1 {
                major.move(to: left); major.addLine(to: right)
            } else {
                minor.move(to: left); minor.addLine(to: right)
            }
            z += spacing
        }

        context.stroke(minor, with: .color(.white.opacity(0.09)), lineWidth: 0.7)
        context.stroke(major, with: .color(.cyan.opacity(0.22)), lineWidth: 1.2)
    }

    private func drawCamera(
        _ context: inout GraphicsContext,
        projection: PlanProjection
    ) {
        let matrix = plan.cameraTransform.matrix
        let origin = matrix.translation
        let forward = -SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let start = projection.map(origin)
        let end = projection.map(origin + SIMD3(forward.x, 0, forward.z) * 0.45)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 2)
    }

    private func drawMarker(
        _ context: inout GraphicsContext,
        point: CGPoint,
        color: Color,
        label: String
    ) {
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
            with: .color(color)
        )
        context.draw(
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(color),
            at: CGPoint(x: point.x + 16, y: point.y)
        )
    }
}

/// A single pixels-per-meter scale is shared by X and Z, so every grid cell is
/// square and spatial distances are not visually distorted by the panel shape.
private struct PlanProjection {
    let minimumX: Float
    let maximumX: Float
    let minimumZ: Float
    let maximumZ: Float
    let worldSpan: Float
    private let center: SIMD2<Float>
    private let scale: CGFloat
    private let drawingCenter: CGPoint

    init(points: [SIMD3<Float>], anchor: SIMD3<Float>, size: CGSize) {
        center = SIMD2(anchor.x, anchor.z)
        let maximumExtent = points.reduce(Float.zero) { current, point in
            max(current, max(abs(point.x - anchor.x), abs(point.z - anchor.z)))
        }
        let required = maximumExtent * 2 + 0.8
        worldSpan = max(ceil(required * 2) / 2, 2)
        minimumX = center.x - worldSpan * 0.5
        maximumX = center.x + worldSpan * 0.5
        minimumZ = center.y - worldSpan * 0.5
        maximumZ = center.y + worldSpan * 0.5
        let usableWidth = max(size.width - 30, 1)
        let usableHeight = max(size.height - 30, 1)
        scale = min(usableWidth, usableHeight) / CGFloat(worldSpan)
        drawingCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
    }

    func map(_ point: SIMD3<Float>) -> CGPoint {
        CGPoint(
            x: drawingCenter.x + CGFloat(point.x - center.x) * scale,
            y: drawingCenter.y + CGFloat(point.z - center.y) * scale
        )
    }
}
