import AgentConfigCore
import AppKit
import SwiftUI

/// One settings file's permissions: default mode plus the allow / ask / deny lists.
struct PermissionsEditor: View {
    @Environment(AppModel.self) private var model
    let title: String
    let locations: [SettingsLocation]
    @State private var selectedID: String
    @State private var search = ""

    init(title: String, locations: [SettingsLocation], initial: SettingsLocation) {
        self.title = title
        self.locations = locations
        _selectedID = State(initialValue: initial.id)
    }

    private var location: SettingsLocation {
        locations.first { $0.id == selectedID } ?? locations[0]
    }

    var body: some View {
        let state = model.state(location)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if locations.count > 1 {
                    Picker("Which file", selection: $selectedID) {
                        ForEach(locations) { loc in
                            let count = model.state(loc).document?.ruleCount ?? 0
                            Text(count > 0 ? "\(loc.title) (\(count))" : loc.title).tag(loc.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                FileHeader(location: location, exists: state.document?.exists ?? false)

                if let error = state.error {
                    Banner(text: error, symbol: "exclamationmark.octagon.fill", tint: .red)
                } else if let doc = state.document {
                    if location.kind == .project || location.kind == .local, doc.ruleCount > 0 {
                        MoveAllBar(location: location, document: doc)
                    }
                    if location.isEditable {
                        DefaultModeRow(location: location, current: doc.defaultMode)
                    }
                    ForEach(RuleDecision.allCases) { decision in
                        let all = doc.rules(decision)
                        RuleSection(
                            decision: decision,
                            rules: all.filter(matchesSearch),
                            total: all.count,
                            location: location
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter rules")
        .navigationTitle(title)
        .navigationSubtitle(location.displayPath)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Re-read the files from disk")
                Button {
                    model.requestAddRule(initial: location)
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .disabled(!location.isEditable)
                .help("Add a permission rule (⌘N)")
            }
        }
        .onAppear { model.currentLocation = location }
        .onChange(of: selectedID) { model.currentLocation = location }
    }

    private func matchesSearch(_ rule: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return rule.localizedCaseInsensitiveContains(q) || Rules.describe(rule).localizedCaseInsensitiveContains(q)
    }
}

struct FileHeader: View {
    @Environment(AppModel.self) private var model
    let location: SettingsLocation
    let exists: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location.detail)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: location.isEditable ? "doc.text" : "lock.doc")
                    .foregroundStyle(.secondary)
                Text(location.displayPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !exists {
                    Text("not created yet")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Button("Reveal in Finder") { model.reveal(location) }
                if exists {
                    Button("Open File") { model.openInEditor(location.url) }
                }
                if location.isEditable {
                    Button("Backups…") { model.sheet = .backups(.settings(location)) }
                }
            }
            .controlSize(.small)
            if !exists && location.isEditable {
                Text("Adding a rule will create this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DefaultModeRow: View {
    @Environment(AppModel.self) private var model
    let location: SettingsLocation
    let current: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default mode").font(.headline)
                Text("How Claude starts out in sessions that use this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Default mode", selection: Binding(
                get: { current ?? "" },
                set: { model.propose(.setDefaultMode($0.isEmpty ? nil : $0), at: location) }
            )) {
                Text("Not set").tag("")
                Divider()
                ForEach(DefaultMode.all) { mode in
                    Text(mode.label).tag(mode.id)
                }
                if let current, !DefaultMode.all.contains(where: { $0.id == current }) {
                    Text(current).tag(current)
                }
            }
            .labelsHidden()
            .frame(width: 290)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

struct RuleSection: View {
    @Environment(AppModel.self) private var model
    let decision: RuleDecision
    let rules: [String]
    let total: Int
    let location: SettingsLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(decision.color)
                    .frame(width: 9, height: 9)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(decision.title).font(.title3.weight(.semibold))
                Text("\(total)").foregroundStyle(.secondary).monospacedDigit()
                Text(decision.explanation).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if location.isEditable {
                    Button {
                        model.requestAddRule(initial: location, decision: decision)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a rule to \(decision.title)")
                }
            }

            VStack(spacing: 0) {
                if rules.isEmpty {
                    Text(total == 0 ? "No rules" : "No matches")
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    if index > 0 { Divider().padding(.leading, 40) }
                    RuleRow(rule: rule, decision: decision, location: location)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }
}

struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: String
    let decision: RuleDecision
    let location: SettingsLocation
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Rules.symbol(rule))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(Rules.describe(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let note = conflictNote {
                Label(note.text, systemImage: note.warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(note.warning ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        if location.isEditable {
            ForEach(RuleDecision.allCases.filter { $0 != decision }) { other in
                Button("Move to \(other.title)") {
                    model.propose(.move(rule, from: decision, to: other), at: location)
                }
            }
            if location.kind == .project || location.kind == .local {
                Button("Move to Everywhere…") {
                    model.moveToEverywhere([(rule, decision)], from: location)
                }
            }
            Divider()
        }
        Button("Copy Rule") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rule, forType: .string)
        }
        if location.isEditable {
            Divider()
            Button("Delete…", role: .destructive) {
                model.propose(.remove(rule, decision), at: location)
            }
        }
    }

    /// Flags when another file that applies here decides the same rule differently.
    private var conflictNote: (text: String, warning: Bool)? {
        let others = model.hits(for: rule, relevantTo: location)
            .filter { !($0.location == location && $0.decision == decision && $0.rule == rule) }
        if let winner = others.filter({ $0.decision.precedence > decision.precedence })
            .max(by: { $0.decision.precedence < $1.decision.precedence }) {
            let place = winner.location == location ? "this file" : model.label(for: winner.location)
            return ("\(winner.decision.title) in \(place) wins", true)
        }
        if let same = others.first(where: { $0.decision == decision && $0.location != location }) {
            return ("Also in \(model.label(for: same.location))", false)
        }
        return nil
    }
}

/// Offers to move a project file's rules into user settings. On the home folder's
/// local file it's a warning, because those rules only apply when Claude starts in ~.
struct MoveAllBar: View {
    @Environment(AppModel.self) private var model
    let location: SettingsLocation
    let document: SettingsDocument

    private var isHome: Bool {
        location.projectRoot.map { ProjectEntry(root: $0).isHome } ?? false
    }

    var body: some View {
        let count = document.ruleCount
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isHome ? "exclamationmark.triangle.fill" : "arrow.up.forward.circle")
                .foregroundStyle(isHome ? .orange : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                if isHome {
                    Text("These \(count) rules only apply when you start Claude from your home folder.")
                        .font(.callout.weight(.semibold))
                    Text("They don't apply in your projects. Move them to Everywhere if you want them in every session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Want these in every project?")
                        .font(.callout.weight(.semibold))
                    Text("Move the \(count) rule\(count == 1 ? "" : "s") in this file to Everywhere. You can also move one rule from its ⋯ menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Move All to Everywhere…") {
                let rules = RuleDecision.allCases.flatMap { d in document.rules(d).map { (rule: $0, decision: d) } }
                model.moveToEverywhere(rules, from: location)
            }
        }
        .padding(12)
        .background((isHome ? Color.orange : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
