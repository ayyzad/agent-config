import AgentConfigCore
import AppKit
import SwiftUI

enum SidebarItem: Hashable {
    case overview, user, managed
    case project(String)
    case dotfile(String)
}

struct LoadState {
    var document: SettingsDocument?
    var error: String?
}

/// A file a change can be saved to.
enum FileTarget: Hashable {
    case settings(SettingsLocation)
    case dotfile(Dotfile)

    var url: URL {
        switch self {
        case .settings(let l): l.url
        case .dotfile(let f): f.url
        }
    }

    var displayPath: String {
        switch self {
        case .settings(let l): l.displayPath
        case .dotfile(let f): Paths.tilde(f.url.path)
        }
    }

    var id: String { url.path }
}

struct FileChange: Identifiable {
    let id = UUID()
    let target: FileTarget
    let oldText: String?
    let newText: String
    let diff: [DiffItem]
    let needsGitignore: Bool
}

/// One or more file changes reviewed and saved together.
struct PendingChange: Identifiable {
    let id = UUID()
    let summary: String
    var notes: [String] = []
    let changes: [FileChange]

    var needsGitignore: Bool { changes.contains(where: \.needsGitignore) }
}

struct AddRuleRequest: Identifiable {
    let id = UUID()
    let targets: [SettingsLocation]
    let initialTarget: SettingsLocation
    let decision: RuleDecision
}

enum ActiveSheet: Identifiable {
    case addRule(AddRuleRequest)
    case review(PendingChange)
    case backups(FileTarget)

    var id: String {
        switch self {
        case .addRule(let r): "add-\(r.id)"
        case .review(let p): "review-\(p.id)"
        case .backups(let t): "backups-\(t.id)"
        }
    }
}

struct RuleHit {
    let location: SettingsLocation
    let decision: RuleDecision
    let rule: String
}

struct OverviewRow: Identifiable, Hashable {
    let id: String
    let rule: String
    let decision: RuleDecision
    let location: SettingsLocation
    let whereLabel: String
}

@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .user
    var projects: [ProjectEntry] = []
    var dotfiles: [Dotfile] = []
    /// Claude Code sessions per project, last 30 days.
    var usage: [String: Int] = [:]
    /// Project ids pinned to the top of the sidebar, in order.
    var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinnedProjects") ?? [] {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinnedProjects") }
    }
    /// Project ids hidden from the sidebar.
    var hidden: [String] = UserDefaults.standard.stringArray(forKey: "hiddenProjects") ?? [] {
        didSet { UserDefaults.standard.set(hidden, forKey: "hiddenProjects") }
    }
    /// Agents whose Dotfiles group is collapsed in the sidebar.
    var collapsedAgents: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedAgents") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsedAgents), forKey: "collapsedAgents") }
    }
    var sheet: ActiveSheet?
    var alertMessage: String?
    var toast: String?
    /// The file shown in the detail pane, used by the Add Rule menu command.
    var currentLocation: SettingsLocation?
    /// Which tab (shared / just me) to open a project on.
    var preferredScope: [String: ScopeKind] = [:]
    /// Bumped on every reload so open file views re-read from disk.
    private(set) var reloadToken = 0

    private(set) var states: [String: LoadState] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let extraProjectsKey = "extraProjectFolders"

    let userLocation = SettingsLocation.user()

    init() {
        reload()
    }

    var managedExists: Bool {
        FileManager.default.fileExists(atPath: SettingsLocation.managed.url.path)
    }

    private var extraProjects: [String] {
        get { UserDefaults.standard.stringArray(forKey: extraProjectsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: extraProjectsKey) }
    }

    var allLocations: [SettingsLocation] {
        [userLocation, .managed] + projects.flatMap(\.locations)
    }

    // MARK: Loading

    func reload() {
        let found = ProjectDiscovery.discover(extra: extraProjects)
        var newStates: [String: LoadState] = [:]
        for location in [userLocation, .managed] + found.flatMap(\.locations) {
            newStates[location.id] = Self.load(location)
        }
        states = newStates
        usage = UsageStats.claudeSessions(for: found)
        // Most used first, then projects with rules, then alphabetical.
        projects = found.sorted { a, b in
            let ua = usage[a.id] ?? 0, ub = usage[b.id] ?? 0
            if ua != ub { return ua > ub }
            let ca = ruleCount(a), cb = ruleCount(b)
            if (ca > 0) != (cb > 0) { return ca > 0 }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        dotfiles = DotfileCatalog.discover()
        seedPinsIfNeeded()
        seedHiddenIfNeeded()
        reloadToken += 1
    }

    private static func load(_ location: SettingsLocation) -> LoadState {
        do {
            return LoadState(document: try SettingsDocument.load(location))
        } catch {
            return LoadState(error: error.localizedDescription)
        }
    }

    func state(_ location: SettingsLocation) -> LoadState {
        states[location.id] ?? LoadState()
    }

    func ruleCount(_ project: ProjectEntry) -> Int {
        project.locations.reduce(0) { $0 + (state($1).document?.ruleCount ?? 0) }
    }

    func project(for location: SettingsLocation) -> ProjectEntry? {
        guard let root = location.projectRoot else { return nil }
        return projects.first { $0.root == root }
    }

    func label(for location: SettingsLocation) -> String {
        switch location.kind {
        case .managed: "Managed policy"
        case .user: "Everywhere"
        case .project: "\(projectName(location)), shared with team"
        case .local: "\(projectName(location)), just me"
        }
    }

    private func projectName(_ location: SettingsLocation) -> String {
        guard let root = location.projectRoot else { return "Project" }
        return ProjectEntry(root: root).name
    }

    /// Other places the same rule appears that apply alongside `location`
    /// (managed, user, and the same project's files).
    func hits(for rule: String, relevantTo location: SettingsLocation) -> [RuleHit] {
        let target = Rules.normalized(rule)
        var result: [RuleHit] = []
        for other in allLocations {
            let relevant = other.projectRoot == nil || other.projectRoot == location.projectRoot
            guard relevant, let doc = state(other).document else { continue }
            for decision in RuleDecision.allCases {
                for r in doc.rules(decision) where Rules.normalized(r) == target {
                    result.append(RuleHit(location: other, decision: decision, rule: r))
                }
            }
        }
        return result
    }

    func overviewRows() -> [OverviewRow] {
        var rows: [OverviewRow] = []
        for location in allLocations {
            guard let doc = state(location).document else { continue }
            for decision in RuleDecision.allCases {
                for (i, rule) in doc.rules(decision).enumerated() {
                    rows.append(OverviewRow(
                        id: "\(location.id)|\(decision.rawValue)|\(i)",
                        rule: rule,
                        decision: decision,
                        location: location,
                        whereLabel: label(for: location)
                    ))
                }
            }
        }
        return rows
    }

    // MARK: Pins

    var pinnedProjects: [ProjectEntry] {
        pinned.compactMap { id in projects.first { $0.id == id } }
    }

    var unpinnedProjects: [ProjectEntry] {
        projects.filter { !pinned.contains($0.id) && !hidden.contains($0.id) }
    }

    func isPinned(_ project: ProjectEntry) -> Bool { pinned.contains(project.id) }

    func togglePin(_ project: ProjectEntry) {
        if let i = pinned.firstIndex(of: project.id) {
            pinned.remove(at: i)
        } else {
            pinned.append(project.id)
            hidden.removeAll { $0 == project.id }
        }
    }

    func movePins(from source: IndexSet, to destination: Int) {
        var visible = pinnedProjects.map(\.id)
        visible.move(fromOffsets: source, toOffset: destination)
        pinned = visible + pinned.filter { !visible.contains($0) }
    }

    /// First launch: pin the five projects you use Claude Code in most.
    private func seedPinsIfNeeded() {
        let key = "pinsSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        pinned = projects.filter { !$0.isHome && (usage[$0.id] ?? 0) > 0 }.prefix(5).map(\.id)
    }

    // MARK: Hidden folders

    var hiddenProjects: [ProjectEntry] {
        projects.filter { hidden.contains($0.id) }
    }

    func isHidden(_ project: ProjectEntry) -> Bool { hidden.contains(project.id) }

    func hide(_ project: ProjectEntry) {
        pinned.removeAll { $0 == project.id }
        if !hidden.contains(project.id) { hidden.append(project.id) }
        if selection == .project(project.id) { selection = .user }
    }

    func unhide(_ project: ProjectEntry) {
        hidden.removeAll { $0 == project.id }
    }

    /// Starts with Downloads hidden; it isn't a project.
    private func seedHiddenIfNeeded() {
        let key = "hiddenSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let downloads = Paths.home.appending(path: "Downloads").path
        if projects.contains(where: { $0.id == downloads }), !hidden.contains(downloads) {
            hidden.append(downloads)
        }
    }

    // MARK: Dotfiles

    func dotfiles(for agent: Agent) -> [Dotfile] {
        dotfiles.filter { $0.agent == agent }
    }

    var dotfileAgents: [Agent] {
        Agent.allCases.filter { !dotfiles(for: $0).isEmpty }
    }

    func dotfile(id: String) -> Dotfile? {
        dotfiles.first { $0.id == id }
    }

    func isExpanded(_ agent: Agent) -> Binding<Bool> {
        Binding(
            get: { !self.collapsedAgents.contains(agent.rawValue) },
            set: { expanded in
                if expanded { self.collapsedAgents.remove(agent.rawValue) } else { self.collapsedAgents.insert(agent.rawValue) }
            }
        )
    }

    // MARK: Navigation

    func select(_ location: SettingsLocation) {
        switch location.kind {
        case .user: selection = .user
        case .managed: selection = .managed
        case .project, .local:
            guard let root = location.projectRoot else { return }
            preferredScope[root.path] = location.kind
            selection = .project(root.path)
        }
    }

    func addProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a project folder to manage its Claude Code settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var extra = extraProjects
        if !extra.contains(url.path) { extra.append(url.path) }
        extraProjects = extra
        hidden.removeAll { $0 == url.path }
        reload()
        selection = .project(url.path)
    }

    func reveal(_ url: URL, fallback: URL? = nil) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: parent.path) ? parent : (fallback ?? parent))
        }
    }

    func reveal(_ location: SettingsLocation) {
        reveal(location.url, fallback: location.projectRoot)
    }

    func openInEditor(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Editing

    func requestAddRule(initial: SettingsLocation? = nil, decision: RuleDecision = .allow) {
        let start = initial ?? currentLocation ?? userLocation
        let target = start.isEditable ? start : userLocation
        var targets: [SettingsLocation] = []
        if let project = project(for: target) { targets += project.locations }
        if !targets.contains(userLocation) { targets.append(userLocation) }
        sheet = .addRule(AddRuleRequest(targets: targets, initialTarget: target, decision: decision))
    }

    private func change(_ target: FileTarget, from oldText: String?, to newText: String) -> FileChange {
        var needsGitignore = false
        if case .settings(let location) = target, location.kind == .local, oldText == nil, let root = location.projectRoot {
            needsGitignore = GitCheck.isIgnored(location.url, repoRoot: root) == false
        }
        return FileChange(
            target: target,
            oldText: oldText,
            newText: newText,
            diff: LineDiff.collapsed(LineDiff.lines(from: oldText ?? "", to: newText)),
            needsGitignore: needsGitignore
        )
    }

    private func review(_ change: PendingChange) {
        if change.changes.isEmpty {
            sheet = nil
            showToast("Nothing to change")
        } else {
            sheet = .review(change)
        }
    }

    /// Builds the change against the file as it is on disk right now and opens the review sheet.
    func propose(_ edit: SettingsEdit, at location: SettingsLocation) {
        guard location.isEditable else {
            alertMessage = SettingsError.readOnly.localizedDescription
            return
        }
        do {
            let doc = try SettingsDocument.load(location)
            let newText = try doc.text(applying: edit)
            let changes = newText == (doc.originalText ?? "") ? [] : [change(.settings(location), from: doc.originalText, to: newText)]
            review(PendingChange(summary: edit.summary, changes: changes))
        } catch {
            sheet = nil
            alertMessage = error.localizedDescription
        }
    }

    /// Moves rules from a project file into your user settings, so they apply in every project.
    func moveToEverywhere(_ rules: [(rule: String, decision: RuleDecision)], from location: SettingsLocation) {
        guard location.isEditable, location.kind == .project || location.kind == .local, !rules.isEmpty else { return }
        do {
            let user = try SettingsDocument.load(userLocation)
            let source = try SettingsDocument.load(location)
            let adds = rules.filter { item in
                !user.rules(item.decision).contains { Rules.normalized($0) == Rules.normalized(item.rule) }
            }
            let newUser = adds.isEmpty ? (user.originalText ?? "") : try user.text(applying: adds.map { .add($0.rule, $0.decision) })
            let newSource = try source.text(applying: rules.map { .remove($0.rule, $0.decision) })

            var changes: [FileChange] = []
            if newUser != (user.originalText ?? "") { changes.append(change(.settings(userLocation), from: user.originalText, to: newUser)) }
            if newSource != (source.originalText ?? "") { changes.append(change(.settings(location), from: source.originalText, to: newSource)) }

            var notes: [String] = []
            let already = rules.count - adds.count
            if already > 0 {
                notes.append("\(already) of these \(already == 1 ? "is" : "are") already in Everywhere, so \(already == 1 ? "it's" : "they're") only removed here.")
            }
            let relative = rules.map(\.rule).filter(Self.usesProjectRelativePath)
            if !relative.isEmpty {
                notes.append("\(relative.joined(separator: ", ")) use\(relative.count == 1 ? "s" : "") a path relative to this project. In Everywhere it will be read relative to your home folder or each project instead, so check it still means what you want.")
            }
            let summary = rules.count == 1
                ? "Move \(rules[0].rule) from \(label(for: location)) to Everywhere"
                : "Move \(rules.count) rules from \(label(for: location)) to Everywhere"
            review(PendingChange(summary: summary, notes: notes, changes: changes))
        } catch {
            sheet = nil
            alertMessage = error.localizedDescription
        }
    }

    static func usesProjectRelativePath(_ rule: String) -> Bool {
        let (tool, specifier) = Rules.split(rule)
        guard ["Read", "Edit", "Write", "Cd"].contains(tool), let spec = specifier else { return false }
        return !(spec.hasPrefix("//") || spec.hasPrefix("~/") || spec.hasPrefix("**"))
    }

    /// Opens the review sheet for a new version of a dotfile.
    func proposeText(_ newText: String, for file: Dotfile, summary: String) {
        guard file.isEditable else {
            alertMessage = file.readOnlyReason ?? SettingsError.readOnly.localizedDescription
            return
        }
        do {
            let current = try String(contentsOf: file.url.resolvingSymlinksInPath(), encoding: .utf8)
            try DotfileIO.validate(newText, oldText: current, format: file.format)
            let changes = newText == current ? [] : [change(.dotfile(file), from: current, to: newText)]
            review(PendingChange(summary: summary, changes: changes))
        } catch {
            sheet = nil
            alertMessage = error.localizedDescription
        }
    }

    func restore(_ backup: Backup, to target: FileTarget) {
        guard let text = try? String(contentsOf: backup.url, encoding: .utf8) else {
            alertMessage = "Couldn't read that backup."
            return
        }
        let note = "Restore the backup from \(backup.date.formatted(date: .abbreviated, time: .shortened))"
        switch target {
        case .settings(let location): propose(.replaceAll(text, note: note), at: location)
        case .dotfile(let file): proposeText(text, for: file, summary: note)
        }
    }

    func commit(_ pending: PendingChange, addToGitignore: Bool) {
        var saved: [String] = []
        do {
            for change in pending.changes {
                switch change.target {
                case .settings(let location):
                    try SettingsWriter.write(change.newText, to: location, expecting: change.oldText)
                    if addToGitignore, change.needsGitignore, let root = location.projectRoot {
                        try GitCheck.ignoreLocalSettings(in: root)
                    }
                case .dotfile(let file):
                    try DotfileIO.validate(change.newText, oldText: change.oldText, format: file.format)
                    try FileWriter.write(change.newText, to: file.url, expecting: change.oldText)
                }
                saved.append(change.target.displayPath)
            }
            sheet = nil
            reload()
            showToast(saved.count == 1 ? "Saved to \(saved[0])" : "Saved \(saved.count) files")
        } catch {
            sheet = nil
            reload()
            let partial = saved.isEmpty ? "" : " Already saved: \(saved.joined(separator: ", "))."
            alertMessage = error.localizedDescription + partial
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

extension RuleDecision {
    var color: Color {
        switch self {
        case .allow: .green
        case .ask: .orange
        case .deny: .red
        }
    }

    var verb: String {
        switch self {
        case .allow: "Allow"
        case .ask: "Ask first"
        case .deny: "Block"
        }
    }
}
