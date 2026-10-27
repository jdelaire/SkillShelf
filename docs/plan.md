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
