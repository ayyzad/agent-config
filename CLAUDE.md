# Agent Config

Native macOS app (SwiftUI, Swift 6, macOS 14+) for viewing and editing AI coding-agent config without a terminal. Public repo: github.com/ayyzad/agent-config (MIT). `README.md` describes what the app does for a user; this file covers how to work on it.

## Commands

- `swift run selftest`: core checks. Reads the real settings files on this Mac but writes only to a temp folder. Run after any change to `AgentConfigCore`.
- `./scripts/build-app.sh --install`: release build, wraps it in `build/Agent Config.app`, ad-hoc signs it and copies it to `~/Applications`. Add `--icon` to redraw `Resources/AppIcon.icns`.
- Only Apple's command-line tools are installed (no Xcode), so there's no XCTest. The tests are the `selftest` executable.

## Layout

- `Sources/AgentConfigCore`: no UI.
  - `JSONValue.swift`: order-preserving JSON parse/serialize. Output matches `JSON.stringify(v, null, 2)`, which is how Claude Code writes settings, so an edit changes only the lines it touches.
  - `ClaudeSettings.swift`: settings scopes (managed / user / project / local), rule edits, `SettingsWriter`.
  - `Rules.swift`: rule parsing, plain-English descriptions, and the Add Rule builder. Writes the `Bash(cmd *)` form; `:*` is treated as the same rule.
  - `Dotfiles.swift`: the root-config catalog per agent, secret masking, and `FileWriter`. Every save goes through `FileWriter`: it refuses if the file changed on disk, backs up to `~/Library/Application Support/AgentConfig/Backups`, follows symlinks and keeps file permissions.
  - `Support.swift`: project discovery from `~/.claude.json`, usage stats, git-ignore check, backups, line diff.
- `Sources/AgentConfig`: the SwiftUI app. `AppModel` holds all state. Every edit becomes a `PendingChange`, which can cover several files, and is shown in the review sheet before anything is written.
- `Sources/selftest`: the checks.

## Decisions and gotchas

- Never write a file without showing a diff and backing it up first. Login files (`auth.json`) are never listed. Secrets are masked on screen by default.
- Project folders are untrusted input. Project settings are refused if `.claude` or the settings file is a link at all, including a dangling one (`SettingsLocation.checkContained`, which uses lstat). Project saves write to the exact checked path (`FileWriter` with `followLinks: false`). User-level files and dotfiles may be links. Any `git` call into a project uses `-c core.fsmonitor=false -c core.hooksPath=/dev/null`, `--no-index` and a clean `GIT_*` environment, because a repo's own git config can otherwise run commands. The self-test covers both.
- `~/.claude.json` is shown read-only (only its `mcpServers` key) because Claude Code rewrites it constantly.
- `~/.claude/settings.local.json` is the *home folder's* local project file, not a user-wide file. Its rules only apply when Claude starts in `~`, and the app warns about this.
- Usage counts are top-level session `.jsonl` files from the last 30 days in `~/.claude/projects`. Sessions in Conductor workspaces (`~/conductor/workspaces/<repo>/<name>`) count toward the main checkout, found through the worktree's `.git` file.
- On macOS 26, a SwiftUI `Table` placed in a `VStack` in the detail column slid under the toolbar and hid its header. Detail views use a root `ScrollView` with the header inside it. Don't put a `Table` back there.
- Screen capture is blocked for the terminal (no Screen Recording permission), so `screencapture` fails. To check the UI, use the debug-only snapshot mode in `DebugSnapshot.swift`:
  `AGENTCONFIG_SNAPSHOT_DIR=<dir> AGENTCONFIG_SNAPSHOT_STEPS=user,panes,add,review perl -e 'alarm 45; exec @ARGV' .build/debug/AgentConfig`
  The real window renders blank (liquid-glass sidebar), but `panes`, `homepane`, `overviewpane` and `dotpane:<agent>:<title>` render the same views in plain windows, and sheets capture fine. The `review` and `movehome` steps only open the preview; they never save. The debug build keeps its preferences under the `AgentConfig` defaults domain (`defaults delete AgentConfig` resets the pins and hidden folders), and the installed app under `com.ayyzad.agentconfig`.

## Next ideas

A dropdown of real MCP server names in Add Rule (plugin servers are named like `plugin_supabase_supabase`). A "needs sign-in" badge from `~/.claude/mcp-needs-auth-cache.json`. Structured editors for Cursor CLI permissions (`~/.cursor/cli-config.json` uses the same allow/deny shape with `Shell(...)`) and Codex `prefix_rule` command rules. Per-project dotfiles (AGENTS.md, `.cursor/rules`, `.mcp.json`).
