//
//  AppSessionStore.swift
//  lighting-simulator-app
//
//  Created by Muhammad Fadjar Al Farisyi on 07/09/26.
//



import Combine
import CoreGraphics
import Foundation

struct DebugSettings: Equatable {
    var isEnabled = false
    var showAnchors = false
    var showLightDirection = true
}

struct EditorPayload: @unchecked Sendable {
    let shotID: UUID
    let photo: CGImage
    let plan: SpatialPlanSnapshot
    let editState: RelightingEditState
    let cachedAnalysis: CachedAnalysis?
}

struct CachedAnalysis: Sendable {
    let normals: NormalBuffer
    let mask: ForegroundMaskBuffer?
}

enum ProjectSessionError: LocalizedError {
    case missingProject
    case missingCapturedPhoto
    case projectNameRequired

    var errorDescription: String? {
        switch self {
        case .missingProject:
            "Project tidak ditemukan."
        case .missingCapturedPhoto:
            "Project belum memiliki foto yang dapat diedit."
        case .projectNameRequired:
            "Masukkan nama project sebelum melanjutkan."
        }
    }
}

@MainActor
final class AppSessionStore: ObservableObject {
    @Published private(set) var projects: [LightingProject] = []
    @Published var currentProject: LightingProject?
    @Published var debugSettings = DebugSettings()
    @Published var userMessage: String?
    @Published var editorPayload: EditorPayload?

    let repository: ProjectRepositoryProtocol
    private var requiresWorldReset = false
    private var draftProjectID: UUID?

    init(repository: ProjectRepositoryProtocol) {
        self.repository = repository
    }

    func load() async {
        do {
            // Empty projects created by older builds were never usable. Keep
            // their files untouched, but do not expose them as resumable work.
            projects = try await repository.loadProjects()
                .filter { !$0.shots.isEmpty }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            userMessage = "Projects could not be loaded: \(error.localizedDescription)"
        }
    }

    /// Creates only an in-memory planning draft. It is intentionally absent
    /// from the project list and repository until capture review is confirmed.
    func beginDraftProject() {
        let project = LightingProject(name: "")
        currentProject = project
        editorPayload = nil
        draftProjectID = project.id
        requiresWorldReset = true
    }

    func select(_ project: LightingProject) {
        currentProject = project
        editorPayload = nil
        draftProjectID = nil
        requiresWorldReset = false
    }

    func consumeWorldResetRequest() -> Bool {
        defer { requiresWorldReset = false }
        return requiresWorldReset
    }

    func updateCurrent(_ mutation: (inout LightingProject) -> Void) {
        guard var project = currentProject else { return }
        mutation(&project)
        project.updatedAt = Date()
        currentProject = project
        guard draftProjectID != project.id else { return }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    func commitCurrentDraft(named name: String, shot: Shot) async throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ProjectSessionError.projectNameRequired }
        guard var project = currentProject,
              draftProjectID == project.id,
              shot.projectID == project.id else {
            throw ProjectSessionError.missingProject
        }

        project.name = cleaned
        project.lights = shot.lights
        project.shots = [shot]
        project.updatedAt = Date()
        try await repository.save(project)

        currentProject = project
        draftProjectID = nil
        projects.removeAll { $0.id == project.id }
        projects.insert(project, at: 0)
    }

    /// Materializes only the latest persisted shot needed by the editor. No AR
    /// state is recreated when resuming an existing project.
    func prepareEditor(projectID: UUID) async throws -> UUID {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ProjectSessionError.missingProject
        }
        guard let shot = project.shots.max(by: { $0.timestamp < $1.timestamp }),
              let imageFileName = shot.imageFileName else {
            throw ProjectSessionError.missingCapturedPhoto
        }

        let imageData = try await repository.imageData(fileName: imageFileName)
        let photo = try await Task.detached(priority: .userInitiated) {
            try ImageOrientationNormalizer(maximumPixelDimension: 2_048)
                .normalize(data: imageData)
        }.value
        let plan = SpatialPlanSnapshot(
            projectID: project.id,
            cameraTransform: shot.cameraTransform,
            cameraCalibration: shot.cameraCalibration,
            subjectPosition: shot.subjectPosition,
            lights: shot.lights
        )
        let cachedAnalysis = await loadAnalysisCache(for: shot)

        select(project)
        editorPayload = EditorPayload(
            shotID: shot.id,
            photo: photo,
            plan: plan,
            editState: shot.editState,
            cachedAnalysis: cachedAnalysis
        )
        return shot.id
    }

    func saveEditorState(
        shotID: UUID,
        plan: SpatialPlanSnapshot,
        parameters: RelightingParameters
    ) async {
        guard var project = currentProject,
              let shotIndex = project.shots.firstIndex(where: { $0.id == shotID }) else {
            return
        }
        project.shots[shotIndex].lights = plan.lights
        project.shots[shotIndex].editState = RelightingEditState(parameters: parameters)
        project.lights = plan.lights
        project.updatedAt = Date()

        do {
            try await repository.save(project)
            currentProject = project
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            }
            if let payload = editorPayload {
                editorPayload = EditorPayload(
                    shotID: shotID,
                    photo: payload.photo,
                    plan: plan,
                    editState: project.shots[shotIndex].editState,
                    cachedAnalysis: payload.cachedAnalysis
                )
            }
        } catch {
            userMessage = "Project could not be saved: \(error.localizedDescription)"
        }
    }

    func shot(id: UUID) -> Shot? {
        currentProject?.shots.first { $0.id == id }
    }

    func saveAnalysisCache(
        shotID: UUID,
        normals: NormalBuffer,
        mask: ForegroundMaskBuffer?
    ) async {
        do {
            let encoded = try await Task.detached(priority: .utility) {
                (
                    try AnalysisCacheCodec.encode(normals),
                    try mask.map(AnalysisCacheCodec.encode)
                )
            }.value
            let normalName = try await repository.saveAnalysisData(
                encoded.0,
                shotID: shotID,
                kind: .normals
            )
            let maskName: String?
            if let maskData = encoded.1 {
                maskName = try await repository.saveAnalysisData(
                    maskData,
                    shotID: shotID,
                    kind: .foregroundMask
                )
            } else {
                maskName = nil
            }

            guard var project = currentProject,
                  let index = project.shots.firstIndex(where: { $0.id == shotID }) else { return }
            project.shots[index].normalCacheFileName = normalName
            project.shots[index].maskCacheFileName = maskName
            project.updatedAt = Date()
            try await repository.save(project)
            currentProject = project
            if let listIndex = projects.firstIndex(where: { $0.id == project.id }) {
                projects[listIndex] = project
            }
            if let payload = editorPayload, payload.shotID == shotID {
                editorPayload = EditorPayload(
                    shotID: payload.shotID,
                    photo: payload.photo,
                    plan: payload.plan,
                    editState: payload.editState,
                    cachedAnalysis: CachedAnalysis(normals: normals, mask: mask)
                )
            }
        } catch {
            // Cache is an optimization. The project remains valid and can fall
            // back to inference if the sidecar cannot be written.
            userMessage = "Analysis cache could not be saved: \(error.localizedDescription)"
        }
    }

    private func loadAnalysisCache(for shot: Shot) async -> CachedAnalysis? {
        guard let normalName = shot.normalCacheFileName else { return nil }
        do {
            let normalData = try await repository.analysisData(fileName: normalName)
            let maskData: Data?
            if let maskName = shot.maskCacheFileName {
                maskData = try? await repository.analysisData(fileName: maskName)
            } else {
                maskData = nil
            }
            return try await Task.detached(priority: .userInitiated) {
                CachedAnalysis(
                    normals: try AnalysisCacheCodec.decodeNormals(normalData),
                    mask: try maskData.map(AnalysisCacheCodec.decodeMask)
                )
            }.value
        } catch {
            // Old projects and damaged caches transparently re-run inference
            // once, then replace the cache with a valid sidecar.
            return nil
        }
    }

}
