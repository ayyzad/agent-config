import AgentConfigCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .addRule(let request): AddRuleSheet(request: request)
            case .review(let change): ReviewChangeSheet(change: change)
            case .backups(let target): BackupsSheet(target: target)
            }
        }
        .alert(
            "Couldn't make that change",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        #if DEBUG
        .task { DebugSnapshot.runIfRequested(model: model) }
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview:
            OverviewView()
        case .managed:
            PermissionsEditor(title: "Managed Policy", locations: [.managed], initial: .managed)
        case .project(let id):
            if let project = model.projects.first(where: { $0.id == id }) {
                let initial = initialLocation(for: project)
                PermissionsEditor(title: project.name, locations: project.locations, initial: initial)
                    .id("\(project.id)|\(initial.id)")
                    .toolbar {
                        ToolbarItem {
                            let pinned = model.isPinned(project)
                            Button {
                                model.togglePin(project)
                            } label: {
                                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                            }
                            .help(pinned ? "Remove from Pinned" : "Pin to the top of the sidebar")
                        }
                    }
            } else {
                ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
            }
        case .dotfile(let id):
            if let file = model.dotfile(id: id) {
                DotfileDetail(file: file).id(file.id)
            } else {
                ContentUnavailableView("File not found", systemImage: "doc.questionmark")
            }
        case .user, nil:
            PermissionsEditor(title: "Everywhere", locations: [model.userLocation], initial: model.userLocation)
        }
    }

    /// Opens on the tab you asked for, else the file that has rules.
    private func initialLocation(for project: ProjectEntry) -> SettingsLocation {
        let locations = project.locations
        if let kind = model.preferredScope[project.id], let match = locations.first(where: { $0.kind == kind }) {
            return match
        }
        let withRules = locations.filter { (model.state($0).document?.ruleCount ?? 0) > 0 }
        return withRules.last ?? locations.last!
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showHidden = false

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            if !model.pinnedProjects.isEmpty {
                Section("Pinned") {
                    ForEach(model.pinnedProjects) { project in
                        ProjectSidebarRow(project: project)
                    }
                    .onMove { model.movePins(from: $0, to: $1) }
                }
            }
            if !model.dotfileAgents.isEmpty {
                Section("Dotfiles") {
                    ForEach(model.dotfileAgents) { agent in
                        DisclosureGroup(isExpanded: model.isExpanded(agent)) {
                            ForEach(model.dotfiles(for: agent)) { file in
                                Label(file.title, systemImage: file.isFolder ? "folder" : (file.isEditable ? "doc.text" : "lock.doc"))
                                    .tag(SidebarItem.dotfile(file.id))
                                    .help(file.displayPath)
                            }
                        } label: {
                            Label(agent.title, systemImage: agent.symbol)
                        }
                    }
                }
            }
            Section("Claude Code Permissions") {
                Label("All Rules", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.overview)
                Label("Everywhere", systemImage: "globe")
                    .badge(model.state(model.userLocation).document?.ruleCount ?? 0)
                    .tag(SidebarItem.user)
                if model.managedExists {
                    Label("Managed Policy", systemImage: "building.columns")
                        .tag(SidebarItem.managed)
                }
            }
            Section("Projects") {
                ForEach(model.unpinnedProjects) { project in
                    ProjectSidebarRow(project: project)
                }
                if !model.hiddenProjects.isEmpty {
                    DisclosureGroup(isExpanded: $showHidden) {
                        ForEach(model.hiddenProjects) { project in
                            ProjectSidebarRow(project: project)
                        }
                    } label: {
                        Label("Hidden (\(model.hiddenProjects.count))", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.addProjectFolder()
            } label: {
                Label("Add Project Folder…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

struct ProjectSidebarRow: View {
    @Environment(AppModel.self) private var model
    let project: ProjectEntry

    var body: some View {
        let count = model.ruleCount(project)
        let sessions = model.usage[project.id] ?? 0
        let pinned = model.isPinned(project)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                Text(sessions > 0 ? "\(project.parentDisplay) · \(sessions) session\(sessions == 1 ? "" : "s")" : project.parentDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: pinned ? "pin.fill" : (count > 0 ? "folder.fill" : "folder"))
        }
        .badge(count)
        .tag(SidebarItem.project(project.id))
        .help("\(project.root.path)\n\(sessions) Claude Code sessions in the last 30 days · \(count) rules")
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin to Top") { model.togglePin(project) }
            if model.isHidden(project) {
                Button("Unhide") { model.unhide(project) }
            } else {
                Button("Hide") { model.hide(project) }
            }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.open(project.root) }
        }
    }
}
