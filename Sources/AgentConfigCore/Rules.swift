import Foundation

public enum Rules {
    /// `Bash(gh pr merge *)` → ("Bash", "gh pr merge *"); `WebSearch` → ("WebSearch", nil).
    public static func split(_ rule: String) -> (tool: String, specifier: String?) {
        let r = rule.trimmingCharacters(in: .whitespaces)
        if let open = r.firstIndex(of: "("), r.hasSuffix(")") {
            let inner = r[r.index(after: open)..<r.index(before: r.endIndex)]
            return (String(r[..<open]), String(inner))
        }
        return (r, nil)
    }

    /// `Bash(npm:*)` and `Bash(npm *)` match the same commands.
    public static func normalized(_ rule: String) -> String {
        var r = rule.trimmingCharacters(in: .whitespaces)
        if r.hasSuffix(":*)") { r = String(r.dropLast(3)) + " *)" }
        return r
    }

    public static func isValid(_ rule: String) -> Bool {
        let (tool, specifier) = split(rule)
        guard !tool.isEmpty, let first = tool.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-*"))
        guard tool.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if let specifier, specifier.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if specifier == nil, rule.contains("(") || rule.contains(")") { return false }
        return true
    }

    /// Plain-English meaning of a rule, shown under it in the app.
    public static func describe(_ rule: String) -> String {
        let (tool, specifier) = split(rule)
        func q(_ s: String) -> String { "“\(s)”" }

        switch tool {
        case "Bash", "PowerShell":
            guard let specifier, specifier != "*" else { return "Any shell command" }
            let inner = split(normalized(rule)).specifier ?? specifier
            if inner.hasSuffix(" *"), !inner.dropLast(2).contains("*") {
                return "Commands starting with \(q(String(inner.dropLast(2))))"
            }
            if inner.contains("*") { return "Commands matching \(q(inner))" }
            return "Exactly \(q(inner))"
        case "Read":
            return specifier.map { "Read files matching \(q($0))" } ?? "Read any file"
        case "Edit":
            return specifier.map { "Edit files matching \(q($0))" } ?? "Edit any file"
        case "Write":
            return specifier.map { "Write files matching \(q($0))" } ?? "Write any file"
        case "Cd":
            return specifier.map { "Change into folders matching \(q($0))" } ?? "Change into any folder"
        case "WebFetch":
            guard let specifier else { return "Fetch any web page" }
            if specifier.hasPrefix("domain:") {
                let domain = specifier.dropFirst("domain:".count)
                return domain == "*" ? "Fetch pages from any site" : "Fetch pages from \(domain)"
            }
            return "Fetch \(q(specifier))"
        case "WebSearch":
            return "Search the web"
        case "Agent", "Task":
            return specifier.map { "Start subagents matching \(q($0))" } ?? "Start any subagent"
        case "Skill":
            return specifier.map { "Use the skill \(q($0))" } ?? "Use any skill"
        default:
            if tool.hasPrefix("mcp__") { return describeMCP(tool) }
            return specifier.map { "\(tool): \($0)" } ?? "The \(tool) tool"
        }
    }

    static func describeMCP(_ tool: String) -> String {
        let parts = tool.dropFirst("mcp__".count).components(separatedBy: "__")
        guard let rawServer = parts.first, !rawServer.isEmpty, rawServer != "*" else { return "Every MCP tool" }
        var server = rawServer
        if server.hasPrefix("plugin_") {
            let rest = server.dropFirst("plugin_".count)
            let halves = rest.split(separator: "_", maxSplits: 1).map(String.init)
            server = halves.count == 2 && halves[0] == halves[1] ? halves[0] : String(rest)
        }
        if parts.count == 1 || parts.last == "*" { return "Every tool on the \(server) MCP server" }
        return "\(parts.dropFirst().joined(separator: "__")) on the \(server) MCP server"
    }

    /// SF Symbol for a rule's tool.
    public static func symbol(_ rule: String) -> String {
        let tool = split(rule).tool
        switch tool {
        case "Bash", "PowerShell": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write": return "pencil"
        case "Cd": return "folder"
        case "WebFetch": return "globe"
        case "WebSearch": return "magnifyingglass"
        case "Agent", "Task": return "person.2"
        case "Skill": return "sparkles"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "gearshape"
        }
    }
}

public enum RuleKind: String, CaseIterable, Identifiable, Sendable {
    case bash, read, edit, webFetch, webSearch, mcp, agent, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bash: "Run a shell command"
        case .read: "Read files"
        case .edit: "Edit files"
        case .webFetch: "Fetch web pages"
        case .webSearch: "Search the web"
        case .mcp: "Use an MCP tool"
        case .agent: "Start a subagent"
        case .custom: "Something else (type the rule)"
        }
    }

    public var symbol: String {
        switch self {
        case .bash: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .webFetch: "globe"
        case .webSearch: "magnifyingglass"
        case .mcp: "puzzlepiece.extension"
        case .agent: "person.2"
        case .custom: "chevron.left.forwardslash.chevron.right"
        }
    }

    public var takesInput: Bool { self != .webSearch }

    public var fieldLabel: String {
        switch self {
        case .bash: "Command"
        case .read, .edit: "Files"
        case .webFetch: "Website"
        case .mcp: "Server or tool"
        case .agent: "Subagent"
        case .custom: "Rule"
        case .webSearch: ""
        }
    }

    public var placeholder: String {
        switch self {
        case .bash: "gh pr merge"
        case .read: "~/Documents/**   (blank = any file)"
        case .edit: "src/**   (blank = any file)"
        case .webFetch: "github.com   (blank = any site)"
        case .mcp: "github   or   github__create_issue"
        case .agent: "Explore   (blank = any subagent)"
        case .custom: "Tool(specifier)"
        case .webSearch: ""
        }
    }

    public var help: String {
        switch self {
        case .bash: "Type the command the way you would in Terminal."
        case .read, .edit: "~/ is your home folder, // is an absolute path, a plain path is relative to the project. ** matches any number of folders."
        case .webFetch: "Use *.example.com to cover subdomains."
        case .mcp: "Use the server name from your MCP config. Add __tool to limit it to one tool."
        case .agent: "Subagent names like Explore, Plan or your own agents."
        case .custom: "Any Claude Code permission rule, e.g. Skill(name) or Cd(~/code/**)."
        case .webSearch: ""
        }
    }
}

public enum BashMatch: String, CaseIterable, Identifiable, Sendable {
    case prefix, exact
    public var id: String { rawValue }
}

public enum RuleBuilder {
    public static func build(kind: RuleKind, input: String, bashMatch: BashMatch = .prefix) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bash:
            guard !s.isEmpty else { return nil }
            if bashMatch == .exact || s.hasSuffix("*") { return "Bash(\(s))" }
            return "Bash(\(s) *)"
        case .read:
            return s.isEmpty ? "Read" : "Read(\(s))"
        case .edit:
            return s.isEmpty ? "Edit" : "Edit(\(s))"
        case .webFetch:
            guard !s.isEmpty else { return "WebFetch" }
            var domain = s
            if domain.hasPrefix("domain:") { domain = String(domain.dropFirst("domain:".count)) }
            for scheme in ["https://", "http://"] where domain.lowercased().hasPrefix(scheme) {
                domain = String(domain.dropFirst(scheme.count))
            }
            if let slash = domain.firstIndex(of: "/") { domain = String(domain[..<slash]) }
            return domain.isEmpty ? nil : "WebFetch(domain:\(domain))"
        case .webSearch:
            return "WebSearch"
        case .mcp:
            guard !s.isEmpty else { return nil }
            if s.hasPrefix("mcp__") { return s }
            return "mcp__" + s.split(whereSeparator: \.isWhitespace).joined(separator: "__")
        case .agent:
            return s.isEmpty ? "Agent" : "Agent(\(s))"
        case .custom:
            return s.isEmpty ? nil : s
        }
    }
}
