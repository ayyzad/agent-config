import Foundation

public enum Agent: String, CaseIterable, Identifiable, Sendable {
    case claude, cursor, codex, grok, gemini

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .grok: "Grok"
        case .gemini: "Gemini CLI"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt"
        case .gemini: "diamond"
        }
    }
}

public enum FileFormat: Sendable {
    case json, toml, markdown, shell, text

    public static func of(_ url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json": .json
        case "toml": .toml
        case "md", "markdown": .markdown
        case "sh", "zsh", "bash": .shell
        default: .text
        }
    }
}

/// A root-level agent config file or folder (in your home folder, not a project).
public struct Dotfile: Identifiable, Hashable, Sendable {
    public let agent: Agent
    public let title: String
    public let detail: String
    public let url: URL
    public let isFolder: Bool
    /// Show only this top-level key of a JSON file (used for ~/.claude.json).
    public let jsonKey: String?
    public let readOnlyReason: String?

    public init(agent: Agent, title: String, detail: String = "", url: URL, isFolder: Bool = false,
                jsonKey: String? = nil, readOnlyReason: String? = nil) {
        self.agent = agent
        self.title = title
        self.detail = detail
        self.url = url
        self.isFolder = isFolder
        self.jsonKey = jsonKey
        self.readOnlyReason = readOnlyReason
    }

    public var id: String { url.path + (jsonKey.map { "#" + $0 } ?? "") }
    public var format: FileFormat { FileFormat.of(url) }
    public var displayPath: String { Paths.tilde(url.path) + (jsonKey.map { "  →  \($0)" } ?? "") }
    public var isEditable: Bool { !isFolder && readOnlyReason == nil }
}

public enum DotfileCatalog {
    /// The root config files that exist on this Mac, grouped by agent in display order.
    public static func discover(home: URL = Paths.home) -> [Dotfile] {
        func at(_ path: String) -> URL { home.appending(path: path) }
        let candidates: [Dotfile] = [
            Dotfile(agent: .claude, title: "Settings", detail: "Everything in your user settings: permissions, hooks, plugins, model, status line. Applies to every session.", url: at(".claude/settings.json")),
            Dotfile(agent: .claude, title: "Memory (CLAUDE.md)", detail: "Instructions Claude reads at the start of every session, in every project.", url: at(".claude/CLAUDE.md")),
            Dotfile(agent: .claude, title: "MCP servers", detail: "Your user-wide MCP servers, from ~/.claude.json.", url: at(".claude.json"), jsonKey: "mcpServers",
                    readOnlyReason: "Claude Code rewrites ~/.claude.json all the time, so editing it here could lose changes. Use `claude mcp add` / `claude mcp remove`, or edit it with Claude Code closed."),
            Dotfile(agent: .claude, title: "Subagents", detail: "Your custom subagents (~/.claude/agents).", url: at(".claude/agents"), isFolder: true),
            Dotfile(agent: .claude, title: "Skills", detail: "Your personal skills (~/.claude/skills). Each one is a folder with a SKILL.md.", url: at(".claude/skills"), isFolder: true),
            Dotfile(agent: .claude, title: "Commands", detail: "Your custom slash commands (~/.claude/commands).", url: at(".claude/commands"), isFolder: true),
            Dotfile(agent: .claude, title: "Hook scripts", detail: "Scripts your hooks run. Which hooks fire, and when, is set in Settings under \"hooks\".", url: at(".claude/hooks"), isFolder: true),

            Dotfile(agent: .cursor, title: "CLI settings", detail: "Cursor's terminal agent: permissions, approval mode, sandbox and display.", url: at(".cursor/cli-config.json")),
            Dotfile(agent: .cursor, title: "MCP servers", detail: "MCP servers for Cursor's editor and CLI.", url: at(".cursor/mcp.json")),
            Dotfile(agent: .cursor, title: "Rules", detail: "Your global Cursor rules.", url: at(".cursor/rules"), isFolder: true),
            Dotfile(agent: .cursor, title: "Skills", detail: "Your Cursor skills.", url: at(".cursor/skills"), isFolder: true),
            Dotfile(agent: .cursor, title: "Agents", detail: "Your Cursor agents.", url: at(".cursor/agents"), isFolder: true),

            Dotfile(agent: .codex, title: "Config", detail: "Model, approvals, sandbox, MCP servers and more.", url: at(".codex/config.toml")),
            Dotfile(agent: .codex, title: "Instructions (AGENTS.md)", detail: "Instructions Codex reads in every session.", url: at(".codex/AGENTS.md")),
            Dotfile(agent: .codex, title: "Command rules", detail: "Commands Codex may run without asking (prefix_rule lines).", url: at(".codex/rules"), isFolder: true),
            Dotfile(agent: .codex, title: "Skills", detail: "Your Codex skills.", url: at(".codex/skills"), isFolder: true),
            Dotfile(agent: .codex, title: "Prompts", detail: "Your Codex custom prompts.", url: at(".codex/prompts"), isFolder: true),

            Dotfile(agent: .grok, title: "Config", detail: "Model, permission mode, plugins and MCP servers.", url: at(".grok/config.toml")),
            Dotfile(agent: .grok, title: "Trusted folders", detail: "Folders Grok is allowed to work in.", url: at(".grok/trusted_folders.toml")),
            Dotfile(agent: .grok, title: "Instructions (AGENTS.md)", detail: "Instructions Grok reads in every session.", url: at(".grok/AGENTS.md")),
            Dotfile(agent: .grok, title: "Skills", detail: "Your Grok skills.", url: at(".grok/skills"), isFolder: true),

            Dotfile(agent: .gemini, title: "Settings", detail: "Gemini CLI settings.", url: at(".gemini/settings.json")),
            Dotfile(agent: .gemini, title: "Memory (GEMINI.md)", detail: "Instructions Gemini reads in every session.", url: at(".gemini/GEMINI.md")),
        ]
        return candidates.filter { file in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDir), isDir.boolValue == file.isFolder else { return false }
            return file.isFolder ? !children(of: file).isEmpty : true
        }
    }

    /// Files inside a folder entry. A subfolder shows its main file (SKILL.md, README.md or its first .md).
    public static func children(of folder: Dotfile) -> [Dotfile] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.url.path)) ?? []
        var result: [Dotfile] = []
        for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) where !name.hasPrefix(".") {
            let url = folder.url.appending(path: name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let inner = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                let main = ["SKILL.md", "README.md", "AGENT.md"].first(where: inner.contains)
                    ?? inner.sorted().first { $0.lowercased().hasSuffix(".md") }
                if let main {
                    result.append(Dotfile(agent: folder.agent, title: name, url: url.appending(path: main)))
                }
            } else if isTextFile(url) {
                result.append(Dotfile(agent: folder.agent, title: name, url: url))
            }
        }
        return result
    }

    static func isTextFile(_ url: URL) -> Bool {
        let textExtensions: Set<String> = ["md", "markdown", "json", "toml", "yaml", "yml", "txt", "rules", "sh", "zsh", "bash", "py", "js", "ts", "mdc"]
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        // Extensionless scripts.
        if ext.isEmpty, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
        }
        return false
    }
}

public enum DotfileIO {
    /// The text shown for a dotfile: the whole file, or just its `jsonKey` subtree.
    public static func read(_ file: Dotfile) throws -> String {
        let text = try String(contentsOf: file.url.resolvingSymlinksInPath(), encoding: .utf8)
        guard let key = file.jsonKey else { return text }
        let root = try JSON.parse(text)
        return JSON.serialize(root[key] ?? .object([])) + "\n"
    }

    /// Blocks saving a JSON file that would no longer parse, unless it didn't parse
    /// before either (some tools allow comments).
    public static func validate(_ newText: String, oldText: String?, format: FileFormat) throws {
        guard format == .json else { return }
        if let oldText, (try? JSON.parse(oldText)) == nil { return }
        _ = try JSON.parse(newText)
    }
}

// MARK: - Writing

public enum FileWriter {
    /// Writes `newText` only if the file still holds `expectedOldText`. Backs up the
    /// current contents first, follows symlinks and keeps the file's permissions.
    @discardableResult
    public static func write(_ newText: String, to url: URL, expecting expectedOldText: String?) throws -> URL? {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: target.path)
        let current = exists ? try String(contentsOf: target, encoding: .utf8) : nil
        guard current == expectedOldText else { throw SettingsError.changedOnDisk }

        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        var backup: URL?
        if let current { backup = try BackupStore.save(current, for: url) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(newText.utf8).write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        return backup
    }
}

// MARK: - Secrets

public enum Secrets {
    private static let mask = "••••••••"

    private static let patterns: [(NSRegularExpression, String)] = {
        let secretWord = "(?:key|token|secret|password|passwd|authorization|credential|cookie|bearer)"
        let specs: [(String, String)] = [
            // JSON: "API_KEY": "value", "Authorization": "Bearer …"
            ("(?i)(\"[^\"\\n]*\(secretWord)[^\"\\n]*\"\\s*:\\s*\")([^\"\\n]+)(\")", "$1\(mask)$3"),
            // TOML / env style: api_key = "value"
            ("(?im)^(\\s*[\\w.\"-]*\(secretWord)[\\w.\"-]*\\s*=\\s*\")([^\"\\n]+)(\")", "$1\(mask)$3"),
            // Bearer tokens and well-known key shapes anywhere.
            ("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]{8,}", "$1\(mask)"),
            ("\\b(sk-|sk_live_|pk_live_|ghp_|gho_|ghs_|github_pat_|xox[abpr]-|AKIA|AIza|glpat-|beui_live_|re_)[A-Za-z0-9_\\-]{8,}", "$1\(mask)"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// The text with secret-looking values replaced by dots.
    public static func masked(_ text: String) -> String {
        var out = text
        for (regex, template) in patterns {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    public static func contains(_ text: String) -> Bool { masked(text) != text }
}
