import CoreGraphics
import CoreML
import Foundation
import simd

nonisolated enum SapiensNormalError: LocalizedError {
    case modelNotInstalled
    case noTensorInput([String])
    case outputNotFound([String])
    case invalidOutput(String)
    case predictionFailed([String])

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            "26 package SapiensNormal belum tersedia di Resources/Models."
        case .noTensorInput(let names):
            "Input tensor model Normal tidak ditemukan: \(names.joined(separator: ", "))."
        case .outputNotFound(let names):
            "Output normal tidak ditemukan: \(names.joined(separator: ", "))."
        case .invalidOutput(let message):
            "Output Sapiens Normal tidak valid: \(message)"
        case .predictionFailed(let messages):
            "Inference Sapiens Normal gagal. \(messages.joined(separator: " | "))"
        }
    }
}

nonisolated private struct NormalModelPrediction {
    let features: MLFeatureProvider
    let computeUnits: String
}

nonisolated private struct NormalTensorLayout {
    let array: MLMultiArray
    let height: Int
    let width: Int
    let channelStride: Int
    let rowStride: Int
    let columnStride: Int

    init(_ array: MLMultiArray) throws {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        if shape.count == 4, shape[0] == 1, shape[1] == 3 {
            height = shape[2]; width = shape[3]
            channelStride = strides[1]; rowStride = strides[2]; columnStride = strides[3]
        } else if shape.count == 3, shape[0] == 3 {
            height = shape[1]; width = shape[2]
            channelStride = strides[0]; rowStride = strides[1]; columnStride = strides[2]
        } else {
            throw SapiensNormalError.invalidOutput("expected NCHW/CHW tiga channel, menerima \(shape)")
        }
        self.array = array
    }

    func value(channel: Int, y: Int, x: Int) throws -> Float {
        let index = channel * channelStride + y * rowStride + x * columnStride
        switch array.dataType {
        case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[index])
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[index]
        case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[index])
        default: throw SapiensNormalError.invalidOutput("dtype \(array.dataType.rawValue) tidak didukung")
        }
    }
}

actor SapiensNormalEstimator: NormalEstimating {
    private let preprocessor = SapiensImagePreprocessor()
    private let renderer = SapiensResultRenderer()
    private let maskEstimator = ForegroundMaskEstimator()
    private let clock = ContinuousClock()

    func estimate(
        image: CGImage,
        computePreference: ComputePreference,
        progress: @escaping @Sendable (AnalysisPhase) async -> Void
    ) async throws -> NormalAnalysisResult {
        guard Self.isInstalled else { throw SapiensNormalError.modelNotInstalled }

        await progress(.masking)
        // Mask failure is non-fatal: normals still produce a useful full-frame editor.
        let mask = try? maskEstimator.estimateMask(from: image)
        try Task.checkCancellation()

        await progress(.preprocessing)
        let input = try preprocessor.prepare(image)
        try Task.checkCancellation()

        await progress(.estimatingNormals)
        let start = clock.now
        let prediction = try predictStaged(input: input.tensor, preference: computePreference)
        let duration = start.duration(to: clock.now)
        let arrays = multiArrayOutputs(prediction.features)
        guard let (name, array) = arrays.first(where: { name, array in
            name.localizedCaseInsensitiveContains("normal") || isThreeChannelTensor(array)
        }) else { throw SapiensNormalError.outputNotFound(Array(prediction.features.featureNames)) }

        let layout = try NormalTensorLayout(array)
        guard layout.width == input.transform.modelWidth,
              layout.height == input.transform.modelHeight else {
            throw SapiensNormalError.invalidOutput(
                "\(name) = \(layout.width)×\(layout.height), expected \(input.transform.modelWidth)×\(input.transform.modelHeight)"
            )
        }

        var normals = [SIMD3<Float>]()
        normals.reserveCapacity(input.transform.contentWidth * input.transform.contentHeight)
        for y in input.transform.paddingTop..<(layout.height - input.transform.paddingBottom) {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in input.transform.paddingLeft..<(layout.width - input.transform.paddingRight) {
                let raw = SIMD3<Float>(
                    try layout.value(channel: 0, y: y, x: x),
                    try layout.value(channel: 1, y: y, x: x),
                    try layout.value(channel: 2, y: y, x: x)
                )
                let length = simd_length(raw)
                normals.append(
                    raw.x.isFinite && raw.y.isFinite && raw.z.isFinite && length > 1e-8
                    ? raw / length : .zero
                )
            }
        }
        let buffer = NormalBuffer(
            width: input.transform.contentWidth,
            height: input.transform.contentHeight,
            normals: normals
        )
        return NormalAnalysisResult(
            originalImage: image,
            normals: buffer,
            foregroundMask: mask,
            normalVisualization: try renderer.makeNormalMap(from: buffer),
            inferenceDuration: duration,
            computeUnits: prediction.computeUnits
        )
    }

    nonisolated static var isInstalled: Bool {
        stageNames.allSatisfy { modelURL(named: $0) != nil }
    }

    private func predictStaged(
        input: MLMultiArray,
        preference: ComputePreference
    ) throws -> NormalModelPrediction {
        var tensor = input
        var computeDescriptions = Set<String>()
        for (index, name) in Self.stageNames.enumerated() {
            guard let url = Self.modelURL(named: name) else { throw SapiensNormalError.modelNotInstalled }
            let prediction = try autoreleasepool {
                try predictModel(url: url, input: tensor, preference: preference)
            }
            computeDescriptions.insert(prediction.computeUnits)
            if index == Self.stageNames.count - 1 {
                return NormalModelPrediction(
                    features: prediction.features,
                    computeUnits: "Staged: " + computeDescriptions.sorted().joined(separator: ", ")
                )
            }
            guard let next = multiArrayOutputs(prediction.features).first?.1 else {
                throw SapiensNormalError.outputNotFound(Array(prediction.features.featureNames))
            }
            tensor = next
        }
        throw SapiensNormalError.invalidOutput("pipeline berhenti sebelum head")
    }

    private func predictModel(
        url: URL,
        input: MLMultiArray,
        preference: ComputePreference
    ) throws -> NormalModelPrediction {
        try CoreMLModelAssetValidator.validate(compiledModelURL: url)
        let candidates: [(MLComputeUnits, String)]
        switch preference {
        case .automatic: candidates = [(.all, "ANE/GPU/CPU"), (.cpuAndGPU, "GPU/CPU fallback")]
        case .cpuAndGPU: candidates = [(.cpuAndGPU, "GPU/CPU")]
        case .cpuOnly: candidates = [(.cpuOnly, "CPU")]
        }

        var failures = [String]()
        for (units, label) in candidates {
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                let model = try MLModel(contentsOf: url, configuration: configuration)
                let inputs = model.modelDescription.inputDescriptionsByName
                    .filter { $0.value.type == .multiArray }.map(\.key)
                guard let inputName = inputs.first else {
                    throw SapiensNormalError.noTensorInput(
                        Array(model.modelDescription.inputDescriptionsByName.keys)
                    )
                }
                let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
                return NormalModelPrediction(
                    features: try model.prediction(from: provider),
                    computeUnits: label
                )
            } catch {
                failures.append("\(label): \(error.localizedDescription)")
            }
        }
        throw SapiensNormalError.predictionFailed(failures)
    }

    private func multiArrayOutputs(_ provider: MLFeatureProvider) -> [(String, MLMultiArray)] {
        provider.featureNames.compactMap { name in
            provider.featureValue(for: name)?.multiArrayValue.map { (name, $0) }
        }
    }

    private func isThreeChannelTensor(_ array: MLMultiArray) -> Bool {
        let shape = array.shape.map(\.intValue)
        return (shape.count == 4 && shape[1] == 3) || (shape.count == 3 && shape[0] == 3)
    }

    nonisolated private static let stageNames = ["SapiensNormalPatch"]
        + (0..<24).map { String(format: "SapiensNormalBlock%02d", $0) }
        + ["SapiensNormalHead"]

    nonisolated private static func modelURL(named name: String) -> URL? {
        externalModelURL(named: name)
            ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models")
            ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    nonisolated private static func externalModelURL(named name: String) -> URL? {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        let url = documents.appendingPathComponent("SapiensModels", isDirectory: true)
            .appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? url : nil
    }
}
