import Foundation

nonisolated enum ProjectVideoKind: String, Sendable {
    case source
    case relit
}

nonisolated protocol ProjectRepositoryProtocol: Sendable {
    func loadProjects() async throws -> [LightingProject]
    func save(_ project: LightingProject) async throws
    func saveImageData(_ data: Data, shotID: UUID) async throws -> String
    func imageData(fileName: String) async throws -> Data
    func saveVideo(
        from sourceURL: URL,
        shotID: UUID,
        kind: ProjectVideoKind
    ) async throws -> String
    func videoURL(fileName: String) async throws -> URL
    func saveAnalysisData(
        _ data: Data,
        shotID: UUID,
        kind: AnalysisCacheKind
    ) async throws -> String
    func analysisData(fileName: String) async throws -> Data
}

actor JSONProjectRepository: ProjectRepositoryProtocol {
    private let directory: URL
    private let projectFile: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("LightingSimulator", isDirectory: true)
        self.projectFile = self.directory.appendingPathComponent("projects.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    }

    func loadProjects() async throws -> [LightingProject] {
        guard FileManager.default.fileExists(atPath: projectFile.path) else { return [] }
        return try decoder.decode([LightingProject].self, from: Data(contentsOf: projectFile))
    }

    func save(_ project: LightingProject) async throws {
        try ensureDirectory()
        var projects = try await loadProjects()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try encoder.encode(projects).write(to: projectFile, options: .atomic)
    }

    func saveImageData(_ data: Data, shotID: UUID) async throws -> String {
        try ensureDirectory()
        let name = "shot-\(shotID.uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    func imageData(fileName: String) async throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    func saveVideo(
        from sourceURL: URL,
        shotID: UUID,
        kind: ProjectVideoKind
    ) async throws -> String {
        try ensureDirectory()
        let name = "shot-\(shotID.uuidString)-\(kind.rawValue).mov"
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return name
    }

    func videoURL(fileName: String) async throws -> URL {
        directory.appendingPathComponent(fileName)
    }

    func saveAnalysisData(
        _ data: Data,
        shotID: UUID,
        kind: AnalysisCacheKind
    ) async throws -> String {
        try ensureDirectory()
        let name = "shot-\(shotID.uuidString)-\(kind.rawValue).bin"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    func analysisData(fileName: String) async throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
