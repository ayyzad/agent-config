import Foundation

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static func tilde(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}

public enum RuleDecision: String, CaseIterable, Identifiable, Sendable {
    case allow, ask, deny

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .allow: "Allow"
        case .ask: "Ask"
        case .deny: "Deny"
        }
    }

    public var explanation: String {
        switch self {
        case .allow: "Claude does these without asking."
        case .ask: "Claude asks you first, every time."
        case .deny: "Claude is blocked from these."
        }
    }

    /// Claude Code checks deny, then ask, then allow; the first match wins.
    public var precedence: Int {
        switch self {
        case .deny: 3
        case .ask: 2
        case .allow: 1
        }
    }
}

public enum ScopeKind: String, Sendable {
    case managed, user, project, local
}

public struct SettingsLocation: Hashable, Identifiable, Sendable {
    public let kind: ScopeKind
    public let url: URL
    public let projectRoot: URL?

    public init(kind: ScopeKind, url: URL, projectRoot: URL?) {
        self.kind = kind
        self.url = url
        self.projectRoot = projectRoot
    }

    public var id: String { url.path }
    public var isEditable: Bool { kind != .managed }
    public var displayPath: String { Paths.tilde(url.path) }

    public var title: String {
        switch kind {
        case .managed: "Managed policy"
        case .user: "Everywhere"
        case .project: "Shared with team"
        case .local: "Just me"
        }
    }

    public var detail: String {
        switch kind {
        case .managed: "Set by your organization. Read-only, and it overrides everything else."
        case .user: "Applies to every project on this Mac."
        case .project: "Lives in the repo, so teammates who pull it get these rules too."
        case .local: "Only on this Mac for this project. Normally git-ignored."
        }
    }

    public static func user(home: URL = Paths.home) -> SettingsLocation {
        SettingsLocation(kind: .user, url: home.appending(path: ".claude/settings.json"), projectRoot: nil)
    }

    public static func project(_ root: URL) -> SettingsLocation {
        SettingsLocation(kind: .project, url: root.appending(path: ".claude/settings.json"), projectRoot: root)
    }

    public static func local(_ root: URL) -> SettingsLocation {
        SettingsLocation(kind: .local, url: root.appending(path: ".claude/settings.local.json"), projectRoot: root)
    }

    public static let managed = SettingsLocation(
        kind: .managed,
        url: URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
        projectRoot: nil
    )
}

public struct DefaultMode: Identifiable, Sendable {
    public let id: String
    public let label: String

    public static let all: [DefaultMode] = [
        DefaultMode(id: "default", label: "Ask before risky actions (standard)"),
        DefaultMode(id: "acceptEdits", label: "Auto-accept file edits"),
        DefaultMode(id: "plan", label: "Plan only, no changes"),
        DefaultMode(id: "auto", label: "Auto mode"),
        DefaultMode(id: "dontAsk", label: "Only allowed actions, never ask"),
        DefaultMode(id: "bypassPermissions", label: "Skip all checks (dangerous)"),
    ]
}

public enum SettingsError: Error, LocalizedError {
    case notAnObject
    case permissionsNotAnObject
    case listNotAnArray(String)
    case readOnly
    case changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .notAnObject: "The file's top level isn't a JSON object, so it can't be edited safely."
        case .permissionsNotAnObject: "\"permissions\" in this file isn't an object, so it can't be edited safely."
        case .listNotAnArray(let key): "\"permissions.\(key)\" in this file isn't a list, so it can't be edited safely."
        case .readOnly: "This file is read-only."
        case .changedOnDisk: "The file changed on disk since you opened the preview (Claude Code may have just written to it). It has been reloaded; try again."
        }
    }
}

public enum SettingsEdit: Sendable {
    case add(String, RuleDecision)
    case remove(String, RuleDecision)
    case move(String, from: RuleDecision, to: RuleDecision)
    case setDefaultMode(String?)
    case replaceAll(String, note: String)

    public var summary: String {
        switch self {
        case .add(let rule, let d): "Add \(rule) to \(d.title)"
        case .remove(let rule, let d): "Remove \(rule) from \(d.title)"
        case .move(let rule, let from, let to): "Move \(rule) from \(from.title) to \(to.title)"
        case .setDefaultMode(let mode): mode.map { "Set the default mode to \($0)" } ?? "Clear the default mode"
        case .replaceAll(_, let note): note
        }
    }
}

public struct SettingsDocument: Sendable {
    public let location: SettingsLocation
    /// nil when the file doesn't exist yet.
    public let originalText: String?
    public let root: JSONValue
    let trailingNewline: Bool

    public var exists: Bool { originalText != nil }

    public static func load(_ location: SettingsLocation) throws -> SettingsDocument {
        let url = location.url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SettingsDocument(location: location, originalText: nil, root: .object([]), trailingNewline: true)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SettingsDocument(location: location, originalText: text, root: .object([]), trailingNewline: true)
        }
        return SettingsDocument(
            location: location,
            originalText: text,
            root: try JSON.parse(text),
            trailingNewline: text.hasSuffix("\n")
        )
    }

    public func rules(_ decision: RuleDecision) -> [String] {
        root["permissions"]?[decision.rawValue]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public var ruleCount: Int {
        RuleDecision.allCases.reduce(0) { $0 + rules($1).count }
    }

    public var defaultMode: String? {
        root["permissions"]?["defaultMode"]?.stringValue
    }

    /// The full new file text after applying `edit`. Everything the edit
    /// doesn't touch keeps its order and formatting.
    public func text(applying edit: SettingsEdit) throws -> String {
        if case .replaceAll(let text, _) = edit {
            _ = try JSON.parse(text)
            return text
        }
        guard root.isObject else { throw SettingsError.notAnObject }
        var root = self.root
        var perms = root["permissions"] ?? .object([])
        guard perms.isObject else { throw SettingsError.permissionsNotAnObject }

        switch edit {
        case .add(let rule, let d):
            perms = try Self.adding(rule, to: d, in: perms)
        case .remove(let rule, let d):
            perms = try Self.removing(rule, from: d, in: perms)
        case .move(let rule, let from, let to):
            perms = try Self.adding(rule, to: to, in: Self.removing(rule, from: from, in: perms))
        case .setDefaultMode(let mode):
            if let mode { perms.set("defaultMode", .string(mode)) } else { perms.remove("defaultMode") }
        case .replaceAll:
            break
        }

        // A new "permissions" block goes first (after "$schema" if present).
        root.set("permissions", perms, insertAt: root.keys.first == "$schema" ? 1 : 0)
        var out = JSON.serialize(root)
        if trailingNewline { out += "\n" }
        return out
    }

    /// Applies several edits in order.
    public func text(applying edits: [SettingsEdit]) throws -> String {
        var doc = self
        var text = originalText ?? ""
        for edit in edits {
            text = try doc.text(applying: edit)
            doc = SettingsDocument(location: location, originalText: text, root: try JSON.parse(text), trailingNewline: text.hasSuffix("\n"))
        }
        return text
    }

    static func list(_ d: RuleDecision, in perms: JSONValue) throws -> [JSONValue] {
        guard let value = perms[d.rawValue] else { return [] }
        guard let items = value.arrayValue else { throw SettingsError.listNotAnArray(d.rawValue) }
        return items
    }

    static func adding(_ rule: String, to d: RuleDecision, in perms: JSONValue) throws -> JSONValue {
        var perms = perms
        var items = try list(d, in: perms)
        if !items.contains(.string(rule)) { items.append(.string(rule)) }
        perms.set(d.rawValue, .array(items), insertAt: canonicalIndex(for: d, in: perms))
        return perms
    }

    static func removing(_ rule: String, from d: RuleDecision, in perms: JSONValue) throws -> JSONValue {
        guard perms[d.rawValue] != nil else { return perms }
        var perms = perms
        var items = try list(d, in: perms)
        items.removeAll { $0 == .string(rule) }
        perms.set(d.rawValue, .array(items))
        return perms
    }

    /// Where a missing allow/ask/deny list goes: keep them in that order.
    static func canonicalIndex(for d: RuleDecision, in perms: JSONValue) -> Int {
        let keys = perms.keys
        let order = RuleDecision.allCases.map(\.rawValue)
        let mine = order.firstIndex(of: d.rawValue)!
        if let next = keys.firstIndex(where: { k in order.firstIndex(of: k).map { $0 > mine } ?? false }) {
            return next
        }
        if let prev = keys.lastIndex(where: { k in order.firstIndex(of: k).map { $0 < mine } ?? false }) {
            return prev + 1
        }
        return keys.count
    }
}

public enum SettingsWriter {
    /// Writes `newText` if the file still contains `expectedOldText`, after
    /// saving a backup of the current contents. Returns the backup's URL.
    @discardableResult
    public static func write(_ newText: String, to location: SettingsLocation, expecting expectedOldText: String?) throws -> URL? {
        guard location.isEditable else { throw SettingsError.readOnly }
        _ = try JSON.parse(newText)
        return try FileWriter.write(newText, to: location.url, expecting: expectedOldText)
    }
}
