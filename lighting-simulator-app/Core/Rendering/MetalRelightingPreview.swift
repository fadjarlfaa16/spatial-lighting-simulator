import MetalKit
import QuartzCore
import SwiftUI

/// UIKit is only the bridge required by MTKView; controls/state stay in SwiftUI.
struct MetalRelightingPreview: UIViewRepresentable {
    let resources: MetalRelightingResources
    let parameters: RelightingParameters
    let onFrame: (Double) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resources: resources, parameters: parameters, onFrame: onFrame, onError: onError)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: resources.device)
        view.colorPixelFormat = .bgra8Unorm
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(parameters)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let resources: MetalRelightingResources
        private var parameters: RelightingParameters
        private let onFrame: (Double) -> Void
        private let onError: (String) -> Void
        private var needsFrame = true
        private var frameCount = 0
        // Never block the UI, and never allow gestures to build an unbounded queue.
        private let inFlight = DispatchSemaphore(value: 2)

        init(resources: MetalRelightingResources, parameters: RelightingParameters,
             onFrame: @escaping (Double) -> Void, onError: @escaping (String) -> Void) {
            self.resources = resources
            self.parameters = parameters
            self.onFrame = onFrame
            self.onError = onError
        }

        func update(_ newest: RelightingParameters) {
            guard newest != parameters else { return }
            parameters = newest
            needsFrame = true // Coalesce: latest state wins at the next display tick.
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            needsFrame = true
        }

        func draw(in view: MTKView) {
            guard needsFrame, inFlight.wait(timeout: .now()) == .success else { return }
            guard let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = resources.queue.makeCommandBuffer() else {
                inFlight.signal()
                return
            }
            do {
                try resources.encode(parameters: parameters, pass: pass, commandBuffer: command)
            } catch {
                inFlight.signal()
                view.isPaused = true
                onError(error.localizedDescription)
                return
            }
            needsFrame = false
            frameCount += 1
            let report = frameCount == 1 || frameCount.isMultiple(of: 30)
            let semaphore = inFlight
            command.addCompletedHandler { [weak self] completed in
                semaphore.signal()
                let milliseconds = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000
                let error = completed.error?.localizedDescription
                guard let self else { return }
                Task { @MainActor in
                    if let error { self.onError(error) }
                    else if report { self.onFrame(milliseconds) }
                }
            }
            command.present(drawable)
            command.commit()
        }
    }
}
