import SwiftUI

struct ProjectView: View {
    @StateObject private var presenter: ProjectPresenter

    init(presenter: ProjectPresenter) {
        _presenter = StateObject(wrappedValue: presenter)
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Text("Projects")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Spacer()
                    Button(action: presenter.createProject) {
                        Label("Create New Project", systemImage: "plus")
                    }
                    .buttonStyle(StudioPrimaryButtonStyle())
                }

                if presenter.projects.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(presenter.projects) { project in
                                projectRow(project)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .foregroundStyle(AppTheme.textPrimary)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Open Project", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { presenter.errorMessage = nil }
        } message: {
            Text(presenter.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 74, weight: .light))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.45))
                .shadow(color: AppTheme.primary.opacity(0.15), radius: 22)
            Text("No projects yet")
                .font(.title2.weight(.medium))
            Text("Create your first lighting project to get started.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func projectRow(_ project: ProjectRowEntity) -> some View {
        Button { presenter.openProject(project.id) } label: {
            HStack(spacing: 18) {
                Group {
                    if let thumbnail = project.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            AppTheme.surfaceRaised
                            Image(systemName: "photo")
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }
                }
                .frame(width: 142, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                    Text("Last modified \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }

                Spacer()

                if presenter.openingProjectID == project.id {
                    ProgressView()
                        .tint(AppTheme.primaryBright)
                        .frame(width: 42, height: 42)
                } else {
                    Image(systemName: "pencil")
                        .frame(width: 42, height: 42)
                        .background(AppTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border))
                }
            }
            .padding(10)
            .background(AppTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(AppTheme.border))
        }
        .buttonStyle(.plain)
        .disabled(presenter.openingProjectID != nil)
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { presenter.errorMessage != nil },
            set: { if !$0 { presenter.errorMessage = nil } }
        )
    }
}
