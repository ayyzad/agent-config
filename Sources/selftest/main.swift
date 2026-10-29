import AgentConfigCore
import Foundation

// Checks the core logic. Reads your real settings files but only writes to a temp folder.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print(condition ? "ok    \(message)" : "FAIL  \(message)")
    if !condition { failures += 1 }
}

let tmp = FileManager.default.temporaryDirectory.appending(path: "agentconfig-selftest-\(UUID().uuidString)")
BackupStore.root = tmp.appending(path: "backups")

// 1. Every real settings file reads and writes back byte-for-byte.
var files = [SettingsLocation.user().url]
for project in ProjectDiscovery.discover(extra: []) { files += project.locations.map(\.url) }
var roundTripped = 0
for url in Set(files) where FileManager.default.fileExists(atPath: url.path) {
    do {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out = JSON.serialize(try JSON.parse(text))
        if text.hasSuffix("\n") { out += "\n" }
        check(out == text, "round-trip \(Paths.tilde(url.path))")
        roundTripped += 1
    } catch {
        check(false, "parse \(Paths.tilde(url.path)): \(error)")
    }
}
check(roundTripped > 0, "found \(roundTripped) real settings files")

// 1b. Usage counts land on real projects (Conductor workspaces count toward their repo).
let discovered = ProjectDiscovery.discover(extra: [])
let usage = UsageStats.claudeSessions(for: discovered)
let top = discovered.map { ($0, usage[$0.id] ?? 0) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
for (project, count) in top.prefix(6) { print("      \(count) sessions  \(Paths.tilde(project.root.path))") }
check(!top.isEmpty, "usage stats found recent Claude Code sessions")

// 2. String escaping matches JavaScript's JSON.stringify.
check(JSON.serialize(.string("a\"b\\c\nd\u{1}é😀/")) == "\"a\\\"b\\\\c\\nd\\u0001é😀/\"", "string escaping")
check((try? JSON.parse("{\"a\":\"\\ud83d\\ude00\"}"))?["a"]?.stringValue == "😀", "surrogate pair escape")
check((try? JSON.parse("{\"a\": 1,}")) == nil, "rejects trailing comma")
check(JSON.serialize(try! JSON.parse("{\"n\": 1.50e3, \"e\": [], \"o\": {}}")) == "{\n  \"n\": 1.50e3,\n  \"e\": [],\n  \"o\": {}\n}", "numbers keep their text; empty containers")

// 3. Rule helpers.
check(RuleBuilder.build(kind: .bash, input: " gh pr merge ") == "Bash(gh pr merge *)", "bash prefix rule")
check(RuleBuilder.build(kind: .bash, input: "git status", bashMatch: .exact) == "Bash(git status)", "bash exact rule")
check(RuleBuilder.build(kind: .webFetch, input: "https://docs.github.com/en/rest") == "WebFetch(domain:docs.github.com)", "webfetch domain")
check(RuleBuilder.build(kind: .mcp, input: "github create_issue") == "mcp__github__create_issue", "mcp rule")
check(Rules.normalized("Bash(gh pr merge:*)") == Rules.normalized("Bash(gh pr merge *)"), ":* equals space-star")
check(Rules.describe("Bash(gh pr merge:*)") == "Commands starting with “gh pr merge”", "describe bash prefix")
check(Rules.describe("mcp__plugin_supabase_supabase__apply_migration") == "apply_migration on the supabase MCP server", "describe plugin mcp")
check(Rules.isValid("Bash(gh pr merge *)") && Rules.isValid("mcp__x__*") && !Rules.isValid("Bash(") && !Rules.isValid("bad rule"), "rule validation")

// 4. Edits on a copy of your user settings change only what they should.
let userLocation = SettingsLocation.user()
let fixture = SettingsLocation(kind: .user, url: tmp.appending(path: "home/.claude/settings.json"), projectRoot: nil)
try FileManager.default.createDirectory(at: fixture.url.deletingLastPathComponent(), withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: userLocation.url.path) {
    try FileManager.default.copyItem(at: userLocation.url, to: fixture.url)
} else {
    try Data("{\n  \"permissions\": {\n    \"allow\": []\n  }\n}\n".utf8).write(to: fixture.url)
}

func reload() throws -> SettingsDocument { try SettingsDocument.load(fixture) }

var doc = try reload()
let rule = "Bash(agentconfig-selftest *)"
let added = try doc.text(applying: .add(rule, .ask))
let diff = LineDiff.lines(from: doc.originalText!, to: added)
let removedLines = diff.filter { $0.kind == .removed }.count
check(removedLines <= 1, "add touches at most one existing line (removed \(removedLines))")
check(diff.filter { $0.kind == .added }.contains { $0.text.contains(rule) }, "add shows the new rule in the diff")

let backup = try SettingsWriter.write(added, to: fixture, expecting: doc.originalText)
check(backup != nil && BackupStore.list(for: fixture.url).count == 1, "write saves a backup first")
doc = try reload()
check(doc.rules(.ask).contains(rule), "rule saved to ask")

let moved = try doc.text(applying: .move(rule, from: .ask, to: .deny))
try SettingsWriter.write(moved, to: fixture, expecting: doc.originalText)
doc = try reload()
check(!doc.rules(.ask).contains(rule) && doc.rules(.deny).contains(rule), "move ask → deny")

let removed = try doc.text(applying: .remove(rule, .deny))
try SettingsWriter.write(removed, to: fixture, expecting: doc.originalText)
doc = try reload()
check(!doc.rules(.deny).contains(rule), "remove")

do {
    try SettingsWriter.write(added, to: fixture, expecting: "stale text")
    check(false, "refuses to write over a file that changed on disk")
} catch SettingsError.changedOnDisk {
    check(true, "refuses to write over a file that changed on disk")
}

// 5. A brand-new file gets a clean layout, with the lists in allow/ask/deny order.
let fresh = SettingsLocation(kind: .local, url: tmp.appending(path: "proj/.claude/settings.local.json"), projectRoot: tmp.appending(path: "proj"))
var freshDoc = try SettingsDocument.load(fresh)
check(!freshDoc.exists, "missing file loads as empty")
try SettingsWriter.write(try freshDoc.text(applying: .add("WebSearch", .deny)), to: fresh, expecting: nil)
freshDoc = try SettingsDocument.load(fresh)
try SettingsWriter.write(try freshDoc.text(applying: .add("Read", .allow)), to: fresh, expecting: freshDoc.originalText)
let freshText = try String(contentsOf: fresh.url, encoding: .utf8)
check(freshText == "{\n  \"permissions\": {\n    \"allow\": [\n      \"Read\"\n    ],\n    \"deny\": [\n      \"WebSearch\"\n    ]\n  }\n}\n", "new file layout")

// 6. Symlinked settings stay symlinks.
let target = tmp.appending(path: "dotfiles/settings.json")
try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("{}\n".utf8).write(to: target)
let linkLocation = SettingsLocation(kind: .user, url: tmp.appending(path: "linkhome/.claude/settings.json"), projectRoot: nil)
try FileManager.default.createDirectory(at: linkLocation.url.deletingLastPathComponent(), withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: linkLocation.url, withDestinationURL: target)
let linkDoc = try SettingsDocument.load(linkLocation)
try SettingsWriter.write(try linkDoc.text(applying: .add("WebSearch", .allow)), to: linkLocation, expecting: linkDoc.originalText)
let stillLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: linkLocation.url.path)) != nil
let targetText = try String(contentsOf: target, encoding: .utf8)
check(stillLink && targetText.contains("WebSearch"), "writes through symlinks")

// 7. Dotfiles: discovery, secret hiding, permission-preserving writes, multi-step edits.
let dots = DotfileCatalog.discover()
check(dots.contains { $0.agent == .claude && $0.title == "Settings" }, "dotfiles include Claude settings")
check(!dots.contains { $0.url.lastPathComponent == "auth.json" }, "login files are never listed")
for agent in Agent.allCases {
    let titles = dots.filter { $0.agent == agent }.map(\.title)
    if !titles.isEmpty { print("      \(agent.title): \(titles.joined(separator: ", "))") }
}
let secretSample = """
{"headers": {"Authorization": "Bearer abcdef1234567890"}, "env": {"API_KEY": "xyz-123"}, "name": "keep me"}
api_token = "tok_999"
url = "https://example.com?k=ghp_abcdefghijklmnop"
"""
let maskedSample = Secrets.masked(secretSample)
check(!maskedSample.contains("abcdef1234567890") && !maskedSample.contains("xyz-123") && !maskedSample.contains("tok_999") && !maskedSample.contains("ghp_abcdefghijklmnop"), "secrets are hidden")
check(maskedSample.contains("keep me") && maskedSample.contains("https://example.com"), "normal values stay visible")
for file in dots where !file.isFolder && file.title == "MCP servers" {
    let raw = try DotfileIO.read(file)
    let shown = Secrets.masked(raw)
    check(!shown.contains("Bearer ") || shown.contains("Bearer ••••••••") || !raw.contains("Bearer "), "\(file.agent.title) MCP tokens are hidden")
}

let script = tmp.appending(path: "hooks/run.sh")
try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
try FileWriter.write("#!/bin/sh\necho bye\n", to: script, expecting: "#!/bin/sh\necho hi\n")
let perms = (try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int) ?? 0
check(perms == 0o755, "writing keeps a script executable")

do {
    try DotfileIO.validate("{ broken", oldText: "{}", format: .json)
    check(false, "blocks saving broken JSON")
} catch {
    check(true, "blocks saving broken JSON")
}

let multi = try SettingsDocument.load(fresh)
let multiText = try multi.text(applying: [.add("Bash(a *)", .allow), .add("Bash(b *)", .deny), .remove("Read", .allow)])
check(multiText.contains("Bash(a *)") && multiText.contains("Bash(b *)") && !multiText.contains("\"Read\""), "several edits apply in order")

try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
