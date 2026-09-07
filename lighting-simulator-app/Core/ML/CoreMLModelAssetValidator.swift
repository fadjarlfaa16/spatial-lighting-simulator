import Foundation

nonisolated enum CoreMLModelAssetError: LocalizedError {
    case unreadableWeights(String)
    case lfsPointer(String)
    case truncatedWeights(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableWeights(model):
            "Bobot \(model) tidak ada atau tidak dapat dibaca. Pasang ulang model Core ML yang lengkap."
        case let .lfsPointer(model):
            "Bobot \(model) masih berupa pointer Git LFS, bukan data model. Pulihkan bobot asli di Mac lalu build dan install ulang app. Mengganti CPU/GPU tidak memperbaiki file ini."
        case let .truncatedWeights(model):
            "Bobot \(model) kosong atau terpotong. Pasang ulang model Core ML yang lengkap."
        }
    }
}

/// Checks the weight layout emitted by this project's Sapiens converter, including
/// development models in Documents. Core ML remains responsible for format/runtime
/// compatibility. This is deliberately a bounded read, not a full weight load/hash.
nonisolated enum CoreMLModelAssetValidator {
    static func validate(compiledModelURL: URL) throws {
        let name = compiledModelURL.lastPathComponent
        let weightURL = compiledModelURL.appendingPathComponent("weights/weight.bin")
        let header: Data
        do {
            let file = try FileHandle(forReadingFrom: weightURL)
            defer { try? file.close() }
            header = try file.read(upToCount: 64) ?? Data()
        } catch {
            throw CoreMLModelAssetError.unreadableWeights(name)
        }
        try validateHeader(header, modelName: name)
    }

    static func validateHeader(_ header: Data, modelName: String) throws {
        if header.starts(with: Data("version https://git-lfs.github.com/spec/v1".utf8)) {
            throw CoreMLModelAssetError.lfsPointer(modelName)
        }
        guard header.count >= 64 else {
            throw CoreMLModelAssetError.truncatedWeights(modelName)
        }
    }
}
