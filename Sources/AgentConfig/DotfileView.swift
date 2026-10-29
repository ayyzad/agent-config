import AgentConfigCore
import AppKit
import SwiftUI

/// A root config file or folder from the Dotfiles section.
struct DotfileDetail: View {
    let file: Dotfile

    var body: some View {
        if file.isFolder {
            DotfolderView(folder: file)
        } else {
            DotfileView(file: file)
        }
    }
}

/// Lists a folder's files (skills, subagents, rules, hook scripts); click one to open it.
struct DotfolderView: View {
    @Environment(AppModel.self) private var model
    let folder: Dotfile
    @State private var open: Dotfile?

    var body: some View {
        if let open {
            DotfileView(file: open, backTitle: folder.title) { self.open = nil }
        } else {
            let _ = model.reloadToken
            let children = DotfileCatalog.children(of: folder)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DotfileHeader(file: folder)
                    VStack(spacing: 0) {
                        if children.isEmpty {
                            Text("This folder is empty.")
                                .foregroundStyle(.secondary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                            if index > 0 { Divider().padding(.leading, 40) }
                            Button {
                                open = child
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: Self.symbol(for: child))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(child.title)
                                        Text(Self.summary(of: child.url))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(folder.title)
            .navigationSubtitle("\(folder.agent.title) · \(children.count) item\(children.count == 1 ? "" : "s")")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.reload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    static func symbol(for file: Dotfile) -> String {
        switch file.format {
        case .markdown: file.url.lastPathComponent == "SKILL.md" ? "sparkles" : "doc.richtext"
        case .shell: "terminal"
        case .json, .toml: "gearshape"
        case .text: "doc.text"
        }
    }

    /// The `description:` from a file's front matter, else its first line of text.
    static func summary(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        let lines = head.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if let index = lines.firstIndex(where: { $0.hasPrefix("description:") }) {
            let value = lines[index].dropFirst("description:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard [">", ">-", "|", "|-", ""].contains(value) else { return value }
            // YAML block text: the indented lines that follow, up to the next key.
            return lines[(index + 1)...]
                .prefix { $0 != "---" && $0.range(of: #"^[A-Za-z_-]+:(\s|$)"#, options: .regularExpression) == nil }
                .joined(separator: " ")
        }
        return lines.first { !$0.isEmpty && $0 != "---" && !$0.hasPrefix("#!") } ?? ""
    }
}

/// Shows a file's text with secrets hidden, and edits it with a reviewed, backed-up save.
struct DotfileView: View {
    @Environment(AppModel.self) private var model
    let file: Dotfile
    var backTitle: String?
    var onBack: (() -> Void)?

    @State private var text = ""
    @State private var loadError: String?
    @State private var draft = ""
    @State private var editing = false
    @State private var showSecrets = false

    init(file: Dotfile, backTitle: String? = nil, onBack: (() -> Void)? = nil) {
        self.file = file
        self.backTitle = backTitle
        self.onBack = onBack
    }

    private var isUserSettings: Bool {
        file.url.path == SettingsLocation.user().url.path && file.jsonKey == nil
    }

    var body: some View {
        let hasSecrets = Secrets.contains(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let backTitle, let onBack {
                    Button(action: onBack) {
                        Label(backTitle, systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }

                DotfileHeader(file: file)

                if let reason = file.readOnlyReason {
                    Banner(text: reason, symbol: "lock.fill", tint: .secondary)
                }
                if isUserSettings {
                    HStack {
                        Text("Permission rules in this file are easier to manage in Everywhere.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Everywhere") { model.selection = .user }
                            .controlSize(.small)
                    }
                }

                if let loadError {
                    Banner(text: loadError, symbol: "exclamationmark.octagon.fill", tint: .red)
                } else if editing {
                    if hasSecrets {
                        Label("Secrets in this file are visible while you edit.", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: CGFloat(max(20, draft.split(separator: "\n", omittingEmptySubsequences: false).count + 4)) * 15)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6)))
                } else {
                    if hasSecrets {
                        HStack(spacing: 8) {
                            Label(showSecrets ? "Secrets are showing" : "Secrets are hidden",
                                  systemImage: showSecrets ? "eye" : "eye.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(showSecrets ? "Hide" : "Show") { showSecrets.toggle() }
                                .controlSize(.small)
                        }
                    }
                    let shown = showSecrets ? text : Secrets.masked(text)
                    Text(shown.isEmpty ? "This file is empty." : shown)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(file.title)
        .navigationSubtitle(file.displayPath)
        .toolbar {
            ToolbarItemGroup {
                if editing {
                    Button("Cancel") { editing = false }
                    Button {
                        model.proposeText(draft, for: file, summary: "Edit \(file.title)")
                    } label: {
                        Label("Review Changes…", systemImage: "checkmark.circle")
                    }
                    .keyboardShortcut("s")
                    .disabled(draft == text)
                    .help("Preview and save your changes (⌘S)")
                } else {
                    Button {
                        load()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Re-read the file from disk")
                    Button {
                        draft = text
                        editing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(!file.isEditable || loadError != nil)
                    .help(file.isEditable ? "Edit this file" : (file.readOnlyReason ?? "Read-only"))
                }
            }
        }
        .task(id: file.id) {
            editing = false
            showSecrets = false
            load()
        }
        .onChange(of: model.reloadToken) {
            load()
            // A successful save reloads; leave edit mode once the file matches the draft.
            if editing, text == draft { editing = false }
        }
    }

    private func load() {
        do {
            text = try DotfileIO.read(file)
            loadError = nil
        } catch {
            text = ""
            loadError = error.localizedDescription
        }
    }
}

struct DotfileHeader: View {
    @Environment(AppModel.self) private var model
    let file: Dotfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !file.detail.isEmpty {
                Text(file.detail).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: file.isFolder ? "folder" : (file.isEditable ? "doc.text" : "lock.doc"))
                    .foregroundStyle(.secondary)
                Text(file.displayPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal in Finder") { model.reveal(file.url) }
                if !file.isFolder {
                    Button("Open File") { model.openInEditor(file.url) }
                }
                if file.isEditable {
                    Button("Backups…") { model.sheet = .backups(.dotfile(file)) }
                }
            }
            .controlSize(.small)
        }
    }
}
