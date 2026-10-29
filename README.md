# Agent Config

A native Mac app for viewing and editing AI coding-agent settings without a terminal. It covers Claude Code permission rules and the root config files (dotfiles) of Claude Code, Cursor, Codex, Grok and Gemini.

## What it does

- Lists every Claude Code settings file on your Mac: user (`~/.claude/settings.json`), each project's shared (`.claude/settings.json`) and local (`.claude/settings.local.json`) file, and the managed policy if one exists (read-only). Projects come from `~/.claude.json`, plus any folder you add.
- Shows Allow / Ask / Deny rules with a plain-English description of each, and flags a rule that a stricter rule elsewhere overrides.
- **Add Rule** builds the rule for you: pick "Run a shell command", type `gh pr merge`, choose Allow / Ask first / Block and which file. It writes `Bash(gh pr merge *)`.
- Move a rule between lists, delete it, or set the default mode.
- **Pinned** sits at the top of the sidebar. On first launch it holds the five projects with the most Claude Code sessions in the last 30 days. Sessions in Conductor workspaces count toward their repo. Right-click a project to pin or unpin it, or use the pin button in the toolbar; drag pinned projects to reorder them. The rest of the projects are sorted by usage.
- **Dotfiles** sits near the top of the sidebar and holds the root config files in your home folder, grouped by agent: Claude Code (settings.json, CLAUDE.md, MCP servers, subagents, skills, hook scripts), Cursor (CLI settings, MCP servers), Codex (config.toml, AGENTS.md, command rules, skills), Grok (config, trusted folders) and Gemini. Only files that exist are listed. View them with secrets hidden (there's a Show button) and edit them with the same preview and backup as rules. `~/.claude.json` shows only its MCP servers, read-only, because Claude Code rewrites that file constantly. Login files like `auth.json` are never listed.
- **Move to Everywhere** moves a project's rules into your user settings so they apply in every project. Use it from a rule's ⋯ menu, or **Move All to Everywhere…** for a whole file. The home folder's `~/.claude/settings.local.json` gets a warning, because its rules only apply when Claude starts in `~`.
- **Hide** a folder you don't need (right-click → Hide). Hidden folders collect under **Hidden** at the bottom of Projects, where you can unhide them. Downloads starts hidden. Their rules still appear in All Rules, because they still apply.
- **All Rules** lists every rule from every file, grouped by file, with search and an Allow/Ask/Deny filter. Click a file heading, double-click a rule, or use **Show** to open its file.

## Safety

- Every change shows a diff before saving.
- The current file is backed up to `~/Library/Application Support/AgentConfig/Backups/` first. **Backups…** restores a backup, also with a diff.
- Only the line you changed moves. Everything else in the file keeps its order and formatting, matching how Claude Code writes the file.
- If Claude Code wrote to the file after the preview opened, the save is refused and the file reloads.
- Symlinked settings files (dotfiles repos) are written through the link and stay links.
- When it creates a new `settings.local.json` that git doesn't ignore, it offers to add it to `.claude/.gitignore`.

## Install

There's no signed download yet, so you build it yourself:

```sh
git clone https://github.com/ayyzad/agent-config.git
cd agent-config
./scripts/build-app.sh --install
```

## Build

Needs only Apple's command-line tools (Swift 6), not full Xcode.

```sh
./scripts/build-app.sh --install    # builds "Agent Config.app" and copies it to ~/Applications
./scripts/build-app.sh --icon       # also regenerates the icon
swift run selftest                  # checks the core against your real settings files (read-only)
swift run AgentConfig               # run without bundling
```

## Layout

- `Sources/AgentConfigCore`: order-preserving JSON, settings files and edits, rule builder and descriptions, backups, diff. No UI.
- `Sources/AgentConfig`: the SwiftUI app.
- `Sources/selftest`: self-checks.

## Next

Structured editors (beyond plain text) for Cursor CLI permissions, Codex command rules and MCP servers; per-project dotfiles (AGENTS.md, .cursor/rules); a "would Claude ask before running X?" tester.

## License

MIT. See `LICENSE`.
