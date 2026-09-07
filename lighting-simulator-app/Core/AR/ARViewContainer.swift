//
//  ARViewContainer.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//

import ARKit
import RealityKit
import SwiftUI

struct ARSceneContent: Equatable {
    var subject: PlannedSubject?
    var lights: [VirtualLight]
    var selectedLightID: UUID?
    var placementPreview: WorldRaycastHit?
    var previewHeight: Float = 1.8
    var showAnchors: Bool
    var showLightDirection: Bool
}

struct ARViewContainer: UIViewRepresentable {
    let sessionService: ARSessionService
    let content: ARSceneContent

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = sessionService.session
        let coaching = ARCoachingOverlayView()
        coaching.session = sessionService.session
        coaching.goal = .tracking
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        var debug: ARView.DebugOptions = []
        if content.showAnchors { debug.insert(.showAnchorOrigins) }
        view.debugOptions = debug

        guard context.coordinator.lastContent != content else { return }
        context.coordinator.lastContent = content
        context.coordinator.render(content, in: view)
    }

    final class Coordinator {
        var lastContent: ARSceneContent?
        private var contentAnchors: [AnchorEntity] = []

        func render(_ content: ARSceneContent, in view: ARView) {
            contentAnchors.forEach { $0.removeFromParent() }
            contentAnchors.removeAll()

            if let subject = content.subject {
                addSubject(subject, to: view)
            }
            for light in content.lights {
                addLight(
                    light,
                    isSelected: light.id == content.selectedLightID,
                    showDirection: content.showLightDirection && light.id == content.selectedLightID,
                    to: view
                )
            }
            if let preview = content.placementPreview {
                addPlacementPreview(preview, height: content.previewHeight, to: view)
            }
        }

        private func addSubject(_ subject: PlannedSubject, to view: ARView) {
            let anchor = AnchorEntity(world: subject.position.simd)
            let base = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.4, 0.035, 0.4), cornerRadius: 0.04),
                materials: [SimpleMaterial(color: .systemCyan, roughness: 0.4, isMetallic: false)]
            )
            base.position.y = 0.02
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 0.055),
                materials: [SimpleMaterial(color: .white, roughness: 0.25, isMetallic: false)]
            )
            marker.position.y = 0.95
            anchor.addChild(base)
            anchor.addChild(marker)
            view.scene.addAnchor(anchor)
            contentAnchors.append(anchor)
        }

        private func addLight(_ light: VirtualLight, isSelected: Bool, showDirection: Bool, to view: ARView) {
            let anchor = AnchorEntity(world: light.position.simd)
            anchor.orientation = light.orientation.simd

            let kelvin = SpatialMath.kelvinToRGB(light.kelvin)
            let color = UIColor(red: CGFloat(kelvin.x), green: CGFloat(kelvin.y), blue: CGFloat(kelvin.z), alpha: 1)
            let head = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.28, 0.18, 0.18), cornerRadius: 0.035),
                materials: [SimpleMaterial(color: color, roughness: 0.25, isMetallic: true)]
            )
            let lens = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.14, 0.14, 0.025), cornerRadius: 0.012),
                materials: [SimpleMaterial(color: color, roughness: 0.1, isMetallic: false)]
            )
            lens.position.z = -0.105
            head.addChild(lens)
            for side: Float in [-1, 1] {
                let yoke = ModelEntity(
                    mesh: .generateBox(size: SIMD3(0.025, 0.29, 0.025), cornerRadius: 0.004),
                    materials: [SimpleMaterial(color: .darkGray, roughness: 0.55, isMetallic: true)]
                )
                yoke.position = SIMD3(side * 0.18, -0.08, 0.02)
                head.addChild(yoke)
            }
            let yokeBar = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.38, 0.025, 0.025), cornerRadius: 0.004),
                materials: [SimpleMaterial(color: .darkGray, roughness: 0.55, isMetallic: true)]
            )
            yokeBar.position.y = -0.22
            head.addChild(yokeBar)
            if isSelected {
                let selection = ModelEntity(
                    mesh: .generateSphere(radius: 0.045),
                    materials: [SimpleMaterial(color: .systemOrange, roughness: 0.3, isMetallic: false)]
                )
                selection.position.y = 0.16
                head.addChild(selection)
            }
            anchor.addChild(head)

            let stand = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.035, light.height, 0.035), cornerRadius: 0.006),
                materials: [SimpleMaterial(color: .darkGray, roughness: 0.7, isMetallic: true)]
            )
            // The stand remains vertical in world space even though the head anchor is aimed.
            let standAnchor = AnchorEntity(world: light.position.simd - SIMD3(0, light.height / 2, 0))
            standAnchor.addChild(stand)
            view.scene.addAnchor(standAnchor)
            contentAnchors.append(standAnchor)
            addTripod(
                at: light.position.simd - SIMD3(0, light.height, 0),
                color: .darkGray,
                to: view
            )

            view.scene.addAnchor(anchor)
            contentAnchors.append(anchor)

            if showDirection, let target = SpatialMath.aimedPoint(for: light) {
                let direction = SpatialMath.effectiveDirection(for: light)
                addBeam(from: light.position.simd, to: target, direction: direction, light: light, view: view)
            }
        }

        private func addPlacementPreview(_ hit: WorldRaycastHit, height: Float, to view: ARView) {
            let headPosition = hit.position.simd + SIMD3(0, height, 0)
            let previewColor = hit.isHorizontal
                ? UIColor.systemGreen.withAlphaComponent(0.55)
                : UIColor.systemRed.withAlphaComponent(0.55)
            let standAnchor = AnchorEntity(world: hit.position.simd + SIMD3(0, height / 2, 0))
            let stand = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.04, height, 0.04), cornerRadius: 0.006),
                materials: [SimpleMaterial(color: previewColor, isMetallic: false)]
            )
            standAnchor.addChild(stand)
            view.scene.addAnchor(standAnchor)
            contentAnchors.append(standAnchor)
            addTripod(at: hit.position.simd, color: previewColor, to: view)

            let headAnchor = AnchorEntity(world: headPosition)
            let head = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.30, 0.20, 0.20), cornerRadius: 0.035),
                materials: [SimpleMaterial(color: previewColor, roughness: 0.3, isMetallic: true)]
            )
            headAnchor.addChild(head)
            view.scene.addAnchor(headAnchor)
            contentAnchors.append(headAnchor)

            let footprintAnchor = AnchorEntity(world: hit.position.simd + SIMD3(0, 0.012, 0))
            let footprint = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.48, 0.018, 0.48), cornerRadius: 0.08),
                materials: [SimpleMaterial(color: previewColor, isMetallic: false)]
            )
            footprintAnchor.addChild(footprint)
            view.scene.addAnchor(footprintAnchor)
            contentAnchors.append(footprintAnchor)
        }

        private func addTripod(at base: SIMD3<Float>, color: UIColor, to view: ARView) {
            let start = base + SIMD3<Float>(0, 0.16, 0)
            for angleDegrees: Float in [0, 120, 240] {
                let angle = angleDegrees * .pi / 180
                let end = base + SIMD3<Float>(cos(angle) * 0.42, 0.025, sin(angle) * 0.42)
                addSupport(from: start, to: end, color: color, view: view)
            }
        }

        private func addSupport(from origin: SIMD3<Float>, to target: SIMD3<Float>, color: UIColor, view: ARView) {
            let delta = target - origin
            let length = simd_length(delta)
            guard length > 0.01 else { return }
            let anchor = AnchorEntity(world: origin + delta / 2)
            anchor.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            let support = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.028, length, 0.028), cornerRadius: 0.005),
                materials: [SimpleMaterial(color: color, roughness: 0.6, isMetallic: true)]
            )
            anchor.addChild(support)
            view.scene.addAnchor(anchor)
            contentAnchors.append(anchor)
        }

        private func addBeam(
            from origin: SIMD3<Float>,
            to target: SIMD3<Float>,
            direction: SIMD3<Float>,
            light: VirtualLight,
            view: ARView
        ) {
            let distance = simd_distance(origin, target)
            guard distance > 0.01 else { return }
            let radius = min(SpatialMath.beamRadius(distance: distance, beamAngleDegrees: light.beamAngle), 3)
            let helper = abs(simd_dot(direction, SIMD3<Float>(0, 1, 0))) > 0.9
                ? SIMD3<Float>(1, 0, 0)
                : SIMD3<Float>(0, 1, 0)
            let right = simd_normalize(simd_cross(direction, helper))
            let up = simd_normalize(simd_cross(right, direction))
            let edgeTargets = [target, target + right * radius, target - right * radius, target + up * radius, target - up * radius]
            for edgeTarget in edgeTargets {
                addBeamRay(from: origin, to: edgeTarget, view: view)
            }
        }

        private func addBeamRay(from origin: SIMD3<Float>, to target: SIMD3<Float>, view: ARView) {
            let delta = target - origin
            let length = simd_length(delta)
            guard length > 0.01 else { return }
            let rayAnchor = AnchorEntity(world: origin + delta / 2)
            rayAnchor.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            let ray = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.008, length, 0.008)),
                materials: [SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.28), isMetallic: false)]
            )
            rayAnchor.addChild(ray)
            view.scene.addAnchor(rayAnchor)
            contentAnchors.append(rayAnchor)
        }
    }
}
