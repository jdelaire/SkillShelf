# SkillShelf plan

macOS app that lists every agent skill installed per harness, shows where it lives, deletes it, and pushes a skill to every harness.

## Scope

Harnesses: Claude Code, Codex, Cursor, OpenCode, Grok, Antigravity. User-level skills and installed plugin skills. No project-level skills. Muse is out of v1.

A harness is shown only when it is installed: its folder exists (`~/.claude`, `~/.codex`, `~/.cursor`, `~/.config/opencode`, `~/.grok`, `~/.gemini`), or for Antigravity also `~/.t3/tools/antigravity-acp` or `/Applications/Antigravity.app`. Sidebar icons come from the installed app (Claude, ChatGPT/Codex, Cursor, Antigravity) and fall back to a terminal symbol.

## Locations

Each root has a kind: `user` (deletable), `builtIn` (read-only), `managed` (read-only, re-downloaded by the harness), `plugin` (removed only by uninstalling the plugin).

| Harness | Roots, in order | Push root |
| --- | --- | --- |
| Claude Code | `~/.claude/skills` user; `~/.claude/skills/synced/*/` managed; enabled user-scope plugins from `~/.claude/plugins/installed_plugins.json` + `enabledPlugins` in `~/.claude/settings.json`, skills at the `skills` path in `<installPath>/.claude-plugin/plugin.json`, default `skills/` | `~/.claude/skills` |
| Codex | `~/.codex/skills` user; `~/.agents/skills` user; `~/.codex/skills/.system` builtIn; enabled plugins from `codex plugin list --json`. Payload: `~/.codex/plugins/cache/<marketplace>/<name>/<version>`, else its `latest` link, else `source.path`. Skills at the `skills` path in `.codex-plugin/plugin.json`, default `skills/`. Marketplaces `openai-bundled` and `openai-primary-runtime` are builtIn | `~/.agents/skills` |
| Cursor | `~/.cursor/skills` user; `~/.agents/skills` user; `~/.claude/skills`, `~/.codex/skills`, `~/.grok/skills` and enabled Claude plugins, labeled "third-party, only if enabled in Cursor"; `~/.cursor/skills-cursor` builtIn | `~/.cursor/skills` |
| OpenCode | `~/.config/opencode/skills` user; `~/.config/opencode/skill` user; `~/.claude/skills`; `~/.agents/skills` | `~/.config/opencode/skills` |
| Antigravity | `~/.gemini/config/skills` user (app and IDE); `~/.gemini/antigravity-cli/skills` user (CLI); `~/.gemini/antigravity/skills` user (legacy); `~/.gemini/antigravity-cli/plugins/*/skills` plugin, read-only | `~/.gemini/config/skills` |
| Grok | `~/.grok/skills` user; `~/.agents/skills`; `~/.claude/skills` unless `[compat.claude] skills = false`; `~/.cursor/skills` unless `[compat.cursor] skills = false` (both read from `~/.grok/config.toml`); `~/.grok/bundled/skills` builtIn. Grok plugins are listed only when `~/.grok/installed-plugins/registry.json` exists | `~/.grok/skills` |

A skill is a direct child folder of a root that holds a `SKILL.md`. Nested skills are out of v1.

Protection follows the canonical target, not the root it was found in. A link in a user root that resolves into a builtIn, managed or plugin folder is protected: the link can be removed, the target never.

Never scanned: `~/.codex/.tmp`, `~/.codex/skill-backups`, `~/.codex/vendor_imports`, marketplace caches and clones, unregistered plugin cache versions, npm caches. Config overrides (OpenCode `skills.paths`, Grok `[skills]` paths and disabled lists) are out of v1; the app shows a note when those config keys are set.

## Model

`SkillEntry`: root, folder name, entry path, `isSymlink`, resolved path, broken-link flag, `name` and `description` from SKILL.md frontmatter, plugin id when kind is `plugin`.

A physical entry is scanned once per root. A harness view is the union of its roots' entries, each tagged "via <root>". Two entries with the same folder name in one harness are flagged as duplicates.

## UI

`NavigationSplitView`, three columns.
- Sidebar: "All locations" (every physical entry once), then one row per harness with its count.
- List: `Table` with name, location, kind badge, link target. Search field filters by name and description.
- Detail: name, description, entry path, resolved path, "seen by" harness chips, buttons Reveal in Finder, Open SKILL.md, Push to all harnesses, Delete.
- Refresh with ⌘R and on app activation.

## System prompts

Read-only global instructions, vendor base prompts and captured requests, one row per installed harness under "System prompts". Project instructions and provider-side text are out of scope. The list groups instructions, OpenCode agent definitions, versioned base prompts and captures. Search filters titles. Missing files and unavailable sources stay visible with a reason.

### Instructions

Sources appear in the harness's load order. Conditional parts say when they apply. Parts that resolve to the same file are flagged as loaded twice. Capture shows what the harness actually sends.

| Harness | Sources | Conditions |
| --- | --- | --- |
| Claude Code | `~/.claude/CLAUDE.md`, recursive `@path` imports up to 4 hops with a cycle guard, and `~/.claude/rules/**/*.md` | Rules with `paths` frontmatter load when a matching file is read. `outputStyle` in `~/.claude/settings.json` selects a user file in `~/.claude/output-styles/`; built-in styles are unavailable. Plugin-forced styles are not detected. |
| Codex | Non-empty `~/.codex/AGENTS.override.md`, else `~/.codex/AGENTS.md`; `instructions` and `developer_instructions` in `config.toml`. `$CODEX_HOME` overrides `~/.codex` | `model_instructions_file` replaces the base prompt. |
| Cursor | User rules are in Cursor's server-side knowledge base | Unavailable locally; managed in Cursor Settings > Rules. |
| OpenCode | `config.json`, `opencode.json`, `opencode.jsonc` merged in that order under `~/.config/opencode`; `~/.config/opencode/AGENTS.md`, else `~/.claude/CLAUDE.md`; every `instructions` file, glob or URL | Recursive `agents/**/*.md`, legacy `agent/**/*.md` and `agent.<name>.prompt` are separate agent definitions that replace the base prompt when selected. `default_agent` marks the active agent; without it, none is marked, and Capture shows which first enabled primary agent OpenCode uses. |
| Grok | Named files `Agents.md`, `Claude.md`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENT.md`, `AGENTS.md` under `$GROK_HOME`, default `~/.grok`, then `~/.claude` and `~/.cursor`; rule dirs `$GROK_HOME/rules`, `~/.claude/rules`, `~/.cursor/rules`, then `[paths].extra_rule_dirs`, each sorted by name | Named files are deduplicated by file identity. Claude and Cursor sources honor their own compat switches in `~/.grok/config.toml`. |
| Antigravity | `~/.gemini/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.gemini/config/AGENTS.md`, `~/.gemini/config/GEMINI.md`; rules in `~/.gemini/config/rules/*.md` and `~/.gemini/antigravity-cli/rules/*.md` | Rules with `trigger: always_on` always load; other triggers are conditional. |
| Muse Code | `run.system_prompt` and `run.developer_prompt` in `~/.config/muse/settings.json`; `~/.claude/CLAUDE.md` and `$CODEX_HOME/AGENTS.md` | `context.foreign_personal_rules` can disable the foreign personal rules. |

OpenCode `{file:<path>}` substitutions resolve relative to the config file, expand `~`, and show the referenced file as the source. `{env:<VAR>}` stays unresolved with a note that the environment supplies it at runtime. Remote instruction URLs load only when selected.

### Base prompt

| Harness | Source |
| --- | --- |
| Codex | `~/.codex/models_cache.json`, one part per model's `model_messages` templates, with the configured model first. Fallback: `https://raw.githubusercontent.com/openai/codex/rust-v<version>/codex-rs/models-manager/prompt.md` |
| OpenCode | Prompt files listed through the GitHub contents API for `anomalyco/opencode` at `v<version>`, under `packages/opencode/src/session/prompt/` |
| Others | Unavailable: "Closed source. Use Capture." |

Fetched prompts are cached at `~/Library/Caches/SkillShelf/prompts/<harness>/<version>/<file>`. Cached files are not fetched again. The version and source appear with the prompt.

### Capture adapters

Only Claude Code, Codex and OpenCode are enabled. Each captured a request with a placeholder credential on this Mac. No adapter allows a Unix socket exception.

| Harness | Redirect and command | Session history or unavailable reason |
| --- | --- | --- |
| Claude Code | `ANTHROPIC_BASE_URL`, placeholder `ANTHROPIC_API_KEY`; `claude -p --no-session-persistence <sentinel>` | Persistence disabled. After exit, cleanup removes only the project directory for this run's unique temporary cwd, including its canonical path spelling. |
| Codex | Provider `skillshelf` points to `<url>/v1`, uses `responses`, placeholder `SKILLSHELF_API_KEY`, WebSockets off; `codex exec --ephemeral --skip-git-repo-check <sentinel>` | `--ephemeral` disables session files. No shared history paths are selected for cleanup. |
| OpenCode | `OPENCODE_CONFIG_CONTENT` selects provider `skillshelf` with `options.baseURL` and a placeholder `apiKey`; `opencode run <sentinel>` | No no-persistence flag. `OPENCODE_DB=:memory:` keeps this session in memory and leaves shared SQLite history untouched. |
| Grok | Disabled | "Requires real login" |
| Muse Code | Disabled | "Placeholder key needs --api-key-stdin, not supported yet" |
| Cursor | Disabled | "Prompt is assembled on Cursor's servers" |
| Antigravity | Disabled | "No verified local redirect" |

### Capture rules

- One capture runs at a time, in a new empty temporary directory, with a unique `SKILLSHELF_CAPTURE_<UUID>` user message.
- The listener binds only to `127.0.0.1` on a free port. `sandbox-exec` permits outbound traffic only to that port. It blocks other network access, other localhost services and Unix sockets. Hooks, MCP servers and plugins inherit the sandbox. If the sandbox cannot be verified, the harness does not run.
- The login environment supplies PATH and home. Credential and proxy variables are stripped before the adapter adds its redirect and placeholder credential. The user's config remains in use, so hooks and stdio MCP servers can run and have local side effects. Remote MCP servers and other blocked connections cannot contribute their text; reported MCP failures become capture notes. Placeholder auth can produce different text from account auth, and provider-side additions are absent.
- Requests support `Content-Length` and chunked framing. Limits are 64 KB of headers, 32 MB per body, 64 MB of bodies in total, 8 concurrent connections and 30 requests. Over-limit requests are dropped with a note. Headers are used only for framing and are never saved or logged. Compressed bodies are stored as base64 with an encoding note; WebSocket upgrades are refused. The listener returns a non-retryable `400` error in the adapter's format.
- The first request with the sentinel and a non-empty tools list is the main request and stops capture. Otherwise capture stops on process exit or after 60 s. A sentinel request without tools is labeled "Main request: best guess"; without the sentinel, the main request is unknown. Other requests are helper calls.
- Cleanup is awaited on success, failure and cancellation: terminate the process group, wait for exit, close the listener and connections, remove the temporary directory. Session controls depend on the harness version. Shared logs, caches and hook or MCP side effects may retain metadata; shared files are not edited or deleted to remove it.
- Captures are JSON at `~/Library/Application Support/SkillShelf/captures/<harness>/<ISO8601 timestamp>.json`, with `0700` directories and `0600` files. They hold the harness, version, command without placeholder values, date, notes, request methods, paths and bodies, and up to the last 4 KB of stderr diagnostics. Anthropic and OpenAI bodies are split into system text, tools and messages; unknown formats show raw JSON.

## Delete

- `builtIn`: disabled, reason shown.
- `managed` (Claude synced): disabled, reason "Claude re-downloads it. Turn it off on claude.ai."
- `plugin`: "Uninstall plugin <id>" with a confirm listing every skill in that plugin. Runs `claude plugin uninstall <id> --scope user`, `codex plugin remove <name>@<marketplace>` or `grok plugin uninstall <name>` through `/bin/zsh -lc` so the login PATH applies. Shows the command output on failure.
- Symlink: dialog with "Remove this link" or "Delete everywhere". Every dialog lists the exact paths it will touch.
- "Delete everywhere" trashes the target folder only when the target sits directly inside a user root. A target anywhere else, such as `~/Developer/personal/jdstack/skills/<name>`, is a source the app never deletes; "Delete everywhere" then becomes "Remove all links".
- Real folder with incoming links: only "Delete everywhere", listing the links. Without incoming links: plain confirm.
- Files and links go to the Trash with `FileManager.trashItem`.
- When a trashed folder was `~/.agents/skills/<name>` and `~/.agents/.skill-lock.json` has `skills.<name>`, remove that one key after the trash succeeds.
- Before any change, re-read each path and abort if it no longer matches the plan.
- Plugin CLIs run as `Process` with the executable path resolved once through the login shell (`/bin/zsh -lc 'command -v <tool>'`), an argument array, the login PATH, stdin closed, cwd set to home, both pipes drained concurrently, and a 120 s timeout.

## Push to all harnesses

Available for `user` entries whose resolved path is a real folder with SKILL.md.

1. Target is the resolved real folder. Protected targets cannot be pushed.
2. For each harness in order Claude Code, Codex, Cursor, OpenCode, Grok: the harness is satisfied when one of its enabled roots (Cursor's third-party roots excluded) holds a folder of that name that resolves to the same target and has a `SKILL.md`. If a folder of that name resolves elsewhere or is broken, report a conflict and skip.
3. Otherwise create the harness's push root if missing and add a relative symlink `<push root>/<name>` pointing to the target. Recompute before the next harness, so the Claude and `~/.agents` links cover OpenCode and Grok without extra links.
4. Show a summary: linked, already present, conflicts.

## Structure

SwiftPM, same layout as SimLease.
- `SkillShelfCore`: harness definitions with an injectable home directory, scanner, frontmatter reader, plugin readers, delete planner, push planner, file operations, `CommandRunner` protocol.
- `SkillShelf`: SwiftUI app executable, not sandboxed.
- `scripts/package-app.sh`: builds `dist/SkillShelf.app`, ad-hoc signed. `Resources/SkillShelf-Info.plist`.
- Tests (Swift Testing, temp home fixtures): scanner kinds, symlinks and broken links; harness views and duplicates; push planner minimal links and conflicts; delete planner incoming links and lock-tracked case; Claude plugin reader.

## Concurrency

`AppModel` is `@MainActor @Observable` and holds an immutable `Sendable` snapshot. Scans run in a `@concurrent` function and return a new snapshot tagged with a generation number; older generations are dropped. Mutations go through one `actor Mutator`, one at a time, then trigger a rescan.

## Delivery

Local git repo at `~/Developer/personal/SkillShelf` on `main`. GitHub repo after the user decides public or private.
