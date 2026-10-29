import Foundation

// MARK: - Projects

public struct ProjectEntry: Identifiable, Hashable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var id: String { root.path }
    public var name: String { isHome ? "Home folder" : root.lastPathComponent }
    public var parentDisplay: String { isHome ? "~" : Paths.tilde(root.deletingLastPathComponent().path) }
    public var isHome: Bool { root.standardizedFileURL.path == Paths.home.standardizedFileURL.path }

    /// In your home folder, the "project" settings file is the user file, so
    /// only the local one is listed.
    public var locations: [SettingsLocation] {
        isHome ? [.local(root)] : [.project(root), .local(root)]
    }
}

public enum ProjectDiscovery {
    /// Folders Claude Code has been run in (from ~/.claude.json), plus any you added.
    public static func discover(extra: [String]) -> [ProjectEntry] {
        var paths = Set(extra)
        let claudeJSON = Paths.home.appending(path: ".claude.json")
        if let data = try? Data(contentsOf: claudeJSON),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = object["projects"] as? [String: Any] {
            paths.formUnion(projects.keys)
        }
        var entries: [ProjectEntry] = []
        for path in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                entries.append(ProjectEntry(root: URL(fileURLWithPath: path)))
            }
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Git

public enum GitCheck {
    /// Whether git ignores `file`. nil when it isn't in a repo or git isn't available.
    public static func isIgnored(_ file: URL, repoRoot: URL) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path, "check-ignore", "-q", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    public static func ignoreLocalSettings(in projectRoot: URL) throws {
        let dir = projectRoot.appending(path: ".claude")
        let file = dir.appending(path: ".gitignore")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "settings.local.json\n"
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}

// MARK: - Backups

public struct Backup: Identifiable, Sendable {
    public let url: URL
    public let date: Date
    public let size: Int
    public var id: URL { url }
}

public enum BackupStore {
    nonisolated(unsafe) public static var root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "AgentConfig/Backups", directoryHint: .isDirectory)

    public static func folder(for file: URL) -> URL {
        let key = file.standardizedFileURL.path.split(separator: "/").joined(separator: "__")
        return root.appending(path: key, directoryHint: .isDirectory)
    }

    @discardableResult
    public static func save(_ text: String, for file: URL) throws -> URL {
        let dir = folder(for: file)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = dir.appending(path: formatter.string(from: Date()) + ".json")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    public static func list(for file: URL) -> [Backup] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(for: file), includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Backup(url: url, date: values?.creationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - Line diff

public struct DiffLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable { case same, added, removed }
    public let id: Int
    public let kind: Kind
    public let text: String
}

public enum DiffItem: Identifiable, Sendable {
    case line(DiffLine)
    case gap(id: Int, count: Int)

    public var id: Int {
        switch self {
        case .line(let l): l.id
        case .gap(let id, _): id
        }
    }
}

public enum LineDiff {
    public static func lines(from old: String, to new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let am = Array(a[prefix..<(a.count - suffix)])
        let bm = Array(b[prefix..<(b.count - suffix)])
        let n = am.count, m = bm.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = am[i] == bm[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var out: [(DiffLine.Kind, String)] = a[..<prefix].map { (.same, $0) }
        var i = 0, j = 0
        while i < n, j < m {
            if am[i] == bm[j] {
                out.append((.same, am[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append((.removed, am[i])); i += 1
            } else {
                out.append((.added, bm[j])); j += 1
            }
        }
        while i < n { out.append((.removed, am[i])); i += 1 }
        while j < m { out.append((.added, bm[j])); j += 1 }
        out += a[(a.count - suffix)...].map { (.same, $0) }

        return out.enumerated().map { DiffLine(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    /// Keeps `context` lines around each change and folds the rest.
    public static func collapsed(_ lines: [DiffLine], context: Int = 3) -> [DiffItem] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed {
            for k in max(0, c - context)...min(lines.count - 1, c + context) { keep.insert(k) }
        }
        var items: [DiffItem] = []
        var gap = 0
        for (index, line) in lines.enumerated() {
            if keep.contains(index) {
                if gap > 0 { items.append(.gap(id: -index, count: gap)); gap = 0 }
                items.append(.line(line))
            } else {
                gap += 1
            }
        }
        if gap > 0 { items.append(.gap(id: -lines.count - 1, count: gap)) }
        return items
    }
}

// MARK: - Usage

public enum UsageStats {
    /// Claude Code sessions per project over the last `days` days, counted from the
    /// transcripts in ~/.claude/projects. Sessions in Conductor workspaces count
    /// toward the repo the workspace was made from.
    public static func claudeSessions(for projects: [ProjectEntry], days: Int = 30) -> [String: Int] {
        let fm = FileManager.default
        let transcripts = Paths.home.appending(path: ".claude/projects")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let dirs = try? fm.contentsOfDirectory(atPath: transcripts.path) else { return [:] }

        var perDir: [String: Int] = [:]
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: transcripts.appending(path: dir), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let recent = files.filter { url in
                guard url.pathExtension == "jsonl" else { return false }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (modified ?? .distantPast) > cutoff
            }.count
            if recent > 0 { perDir[dir] = recent }
        }

        var result: [String: Int] = [:]
        for project in projects {
            result[project.id, default: 0] += perDir[encode(project.root.path)] ?? 0
        }

        // Conductor: ~/conductor/workspaces/<repo>/<workspace> → that repo's main checkout.
        let workspacesRoot = Paths.home.appending(path: "conductor/workspaces")
        let prefix = encode(workspacesRoot.path) + "-"
        let repos = ((try? fm.contentsOfDirectory(atPath: workspacesRoot.path)) ?? [])
            .sorted { $0.count > $1.count } // longest name first, so "content-engine-v1" beats "content-engine"
        for (dir, count) in perDir where dir.hasPrefix(prefix) {
            guard let repo = repos.first(where: { dir.hasPrefix(prefix + encode($0) + "-") }),
                  let project = mainProject(forConductorRepo: repo, in: workspacesRoot, projects: projects) else { continue }
            result[project.id, default: 0] += count
        }
        return result
    }

    /// Finds the main checkout through any live workspace's `.git` file, else by folder name.
    static func mainProject(forConductorRepo repo: String, in workspacesRoot: URL, projects: [ProjectEntry]) -> ProjectEntry? {
        let repoDir = workspacesRoot.appending(path: repo)
        for workspace in (try? FileManager.default.contentsOfDirectory(atPath: repoDir.path)) ?? [] {
            let gitFile = repoDir.appending(path: workspace).appending(path: ".git")
            guard let text = try? String(contentsOf: gitFile, encoding: .utf8),
                  let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: "),
                  let range = line.range(of: "/.git/worktrees/") else { continue }
            let root = String(line[line.index(line.startIndex, offsetBy: 8)..<range.lowerBound])
            if let match = projects.first(where: { $0.root.path == root }) { return match }
        }
        let byName = projects.filter { $0.name == repo && !$0.root.path.contains("/conductor/workspaces/") }
        return byName.count == 1 ? byName[0] : nil
    }

    /// Claude Code names transcript folders after the path with every other character as "-".
    static func encode(_ path: String) -> String {
        String(path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
    }
}
