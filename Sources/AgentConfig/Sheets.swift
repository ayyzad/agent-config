import AgentConfigCore
import AppKit
import SwiftUI

// MARK: - Add rule

struct AddRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AddRuleRequest

    @State private var decision: RuleDecision
    @State private var kind: RuleKind = .bash
    @State private var input = ""
    @State private var bashMatch: BashMatch = .prefix
    @State private var targetID: String

    init(request: AddRuleRequest) {
        self.request = request
        _decision = State(initialValue: request.decision)
        _targetID = State(initialValue: request.initialTarget.id)
    }

    private var target: SettingsLocation {
        request.targets.first { $0.id == targetID } ?? request.initialTarget
    }

    private var rule: String? {
        RuleBuilder.build(kind: kind, input: input, bashMatch: bashMatch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a Permission Rule")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)

            Form {
                Picker("Claude should", selection: $decision) {
                    ForEach(RuleDecision.allCases) { Text($0.verb).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("When it wants to", selection: $kind) {
                    ForEach(RuleKind.allCases) { k in
                        Label(k.title, systemImage: k.symbol).tag(k)
                    }
                }

                if kind.takesInput {
                    TextField(kind.fieldLabel, text: $input, prompt: Text(kind.placeholder))
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                }

                if kind == .bash {
                    Picker("Match", selection: $bashMatch) {
                        Text("This command with any arguments").tag(BashMatch.prefix)
                        Text("Only this exact command").tag(BashMatch.exact)
                    }
                    .pickerStyle(.radioGroup)
                }

                if !kind.help.isEmpty {
                    Text(kind.help).font(.caption).foregroundStyle(.secondary)
                }

                Picker("Save in", selection: $targetID) {
                    ForEach(request.targets) { loc in
                        Text(model.label(for: loc)).tag(loc.id)
                    }
                }

                Section("Preview") {
                    preview
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(target.displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Review Change…") {
                    if let rule { model.propose(.add(rule, decision), at: target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 580)
    }

    @ViewBuilder
    private var preview: some View {
        if let rule {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(decision.color).frame(width: 8, height: 8)
                    Text(rule)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("\(decision.verb): \(Rules.describe(rule))")
                    .foregroundStyle(.secondary)
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        } else {
            Text("Fill in the details above.").foregroundStyle(.secondary)
        }
    }

    private var alreadyThere: Bool {
        guard let rule, let doc = model.state(target).document else { return false }
        return doc.rules(decision).contains { Rules.normalized($0) == Rules.normalized(rule) }
    }

    private var canSave: Bool {
        guard let rule else { return false }
        return Rules.isValid(rule) && !alreadyThere
    }

    private var warnings: [String] {
        guard let rule else { return [] }
        var result: [String] = []
        if !Rules.isValid(rule) {
            result.append("This doesn't look like a valid rule. Expected Tool or Tool(specifier).")
        }
        if alreadyThere {
            result.append("This rule is already in \(decision.title) in this file.")
        }
        for hit in model.hits(for: rule, relevantTo: target) where hit.decision != decision {
            let place = hit.location == target ? "this file" : model.label(for: hit.location)
            if hit.decision.precedence > decision.precedence {
                result.append("\(hit.decision.title) in \(place) already covers this and will win.")
            } else {
                result.append("Also in \(hit.decision.title) in \(place). \(decision.title) wins over it.")
            }
        }
        if decision == .allow, ["Bash", "Bash(*)"].contains(rule) {
            result.append("This lets Claude run any shell command without asking.")
        }
        return result
    }
}

// MARK: - Review

struct ReviewChangeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let change: PendingChange
    @State private var addToGitignore = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Change").font(.title2.weight(.semibold))
            Text(change.summary).font(.headline).textSelection(.enabled)

            ForEach(change.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(change.changes) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(file.target.displayPath + (file.oldText == nil ? "  (new file)" : ""))
                            .font(.callout.monospaced())
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                    .foregroundStyle(.secondary)
                    if let real = file.realPath {
                        Label("This is a link. The change is saved to \(real).", systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    DiffView(items: file.diff)
                }
            }

            if change.needsGitignore {
                Toggle("Add settings.local.json to .claude/.gitignore so it isn't committed", isOn: $addToGitignore)
            }
            Text(change.changes.allSatisfy { $0.oldText == nil }
                 ? "The file will be created."
                 : "Each existing file is backed up first. You can restore it from Backups.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.commit(change, addToGitignore: change.needsGitignore && addToGitignore)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: change.changes.count > 1 ? 680 : 520)
    }
}

struct DiffView: View {
    let items: [DiffItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case .gap(_, let count):
                        Text("    ⋯ \(count) unchanged line\(count == 1 ? "" : "s")")
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    case .line(let line):
                        Text(marker(line.kind) + " " + line.text)
                            .foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .background(background(line.kind))
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .same: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .added: .green.opacity(0.18)
        case .removed: .red.opacity(0.18)
        }
    }
}

// MARK: - Backups

struct BackupsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: FileTarget
    @State private var backups: [Backup] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backups").font(.title2.weight(.semibold))
            Text(target.displayPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            if backups.isEmpty {
                ContentUnavailableView(
                    "No backups yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("A copy of this file is saved every time Agent Config changes it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.date.formatted(date: .abbreviated, time: .standard))
                            Text(backup.date, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(backup.size), countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Restore…") { model.restore(backup, to: target) }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            HStack {
                Button("Show in Finder") {
                    let folder = BackupStore.folder(for: target.url)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .onAppear { backups = BackupStore.list(for: target.url) }
    }
}
