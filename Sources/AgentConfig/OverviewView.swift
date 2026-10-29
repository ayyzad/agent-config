import AgentConfigCore
import AppKit
import SwiftUI

/// Every rule from every settings file, grouped by file and searchable.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var filter: RuleDecision?

    private struct Group: Identifiable {
        let location: SettingsLocation
        let rows: [OverviewRow]
        var id: String { location.id }
    }

    private var groups: [Group] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var order: [SettingsLocation] = []
        var byFile: [String: [OverviewRow]] = [:]
        for row in model.overviewRows() {
            guard filter == nil || row.decision == filter else { continue }
            if !q.isEmpty,
               !row.rule.localizedCaseInsensitiveContains(q),
               !row.whereLabel.localizedCaseInsensitiveContains(q),
               !Rules.describe(row.rule).localizedCaseInsensitiveContains(q) { continue }
            if byFile[row.location.id] == nil { order.append(row.location) }
            byFile[row.location.id, default: []].append(row)
        }
        return order.map { Group(location: $0, rows: byFile[$0.id] ?? []) }
    }

    var body: some View {
        let groups = groups
        let total = groups.reduce(0) { $0 + $1.rows.count }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 12) {
                    Label("Claude checks Deny first, then Ask, then Allow, and the first match wins whichever file it's in. Project rules only apply inside that project.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Picker("Show", selection: $filter) {
                        Text("All").tag(RuleDecision?.none)
                        ForEach(RuleDecision.allCases) { Text($0.title).tag(RuleDecision?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if groups.isEmpty {
                    ContentUnavailableView.search(text: search)
                        .frame(maxWidth: .infinity)
                }

                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            model.select(group.location)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(model.label(for: group.location)).font(.title3.weight(.semibold))
                                Text("\(group.rows.count)").foregroundStyle(.secondary).monospacedDigit()
                                Text(group.location.displayPath)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this file")

                        LazyVStack(spacing: 0) {
                            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().padding(.leading, 40) }
                                OverviewRuleRow(row: row)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search all rules")
        .navigationTitle("All Rules")
        .navigationSubtitle("\(total) rules in \(groups.count) files")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Re-read the files from disk")
                Button {
                    model.requestAddRule(initial: model.userLocation)
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .help("Add a permission rule (⌘N)")
            }
        }
        .onAppear { model.currentLocation = nil }
    }
}

private struct OverviewRuleRow: View {
    @Environment(AppModel.self) private var model
    let row: OverviewRow
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Rules.symbol(row.rule))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.rule)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(Rules.describe(row.rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(row.decision.color).frame(width: 8, height: 8)
                Text(row.decision.title)
            }
            .font(.callout)
            .frame(width: 64, alignment: .leading)
            Button("Show") { model.select(row.location) }
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
                .help("Open the file this rule is in")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.select(row.location) }
        .contextMenu {
            Button("Show in File") { model.select(row.location) }
            Button("Copy Rule") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.rule, forType: .string)
            }
        }
    }
}
