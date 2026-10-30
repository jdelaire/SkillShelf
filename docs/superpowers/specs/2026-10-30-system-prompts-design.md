# System prompts view

## Goal

Show, read-only, what each installed harness puts in front of the model before the user's first message. Three layers per harness:

1. Instructions: global user files and config keys that inject text.
2. Base prompt: the vendor's built-in prompt for the installed version.
3. Capture: the full request body the harness sends, recorded on a loopback listener.

Out of scope: editing any file, project-level instructions, comparing harnesses or versions, extracting strings from binaries, provider-side text that never leaves the vendor's servers.

## Facts this design relies on

Verified on this Mac on 2026-10-30. Versions: Claude Code 2.1.312, Codex 0.164.0, Cursor 3.26.16, OpenCode 1.19.5, Grok 1.0.70, Antigravity CLI (`agy`) 1.4.9, Muse Code 1.4.14.

### Instructions, in load order

| Harness | Sources |
| --- | --- |
| Claude Code | `~/.claude/CLAUDE.md` and its `@path` imports; `~/.claude/rules/**/*.md`; the output style named by `outputStyle` in `~/.claude/settings.json`, read from `~/.claude/output-styles/<name>.md` |
| Codex | `~/.codex/AGENTS.override.md` if non-empty, else `~/.codex/AGENTS.md` (`$CODEX_HOME` overrides `~/.codex`); `config.toml` keys `model_instructions_file` (replaces the built-in prompt), `instructions`, `developer_instructions` |
| Cursor | Unavailable. User rules come from Cursor's server-side knowledge base. The legacy SQLite key `aicontext.personalContext` is not reliable. |
| OpenCode | `~/.config/opencode/AGENTS.md`, else `~/.claude/CLAUDE.md`; every entry of `instructions` in `~/.config/opencode/opencode.jsonc` (files, globs, URLs); `~/.config/opencode/agents/*.md` and legacy `agent/` |
| Grok | First present of `Agents.md`, `Claude.md`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENT.md`, `AGENTS.md` under `$GROK_HOME` (default `~/.grok`); `~/.claude/CLAUDE.md` unless Claude compat is off; rule dirs `~/.grok/rules`, `~/.claude/rules`, `~/.cursor/rules`, then `[paths].extra_rule_dirs`, each sorted by name |
| Antigravity | `~/.gemini/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.gemini/config/AGENTS.md`, `~/.gemini/config/GEMINI.md`, `~/.gemini/config/rules/*.md`, `~/.gemini/antigravity-cli/rules/*.md` |
| Muse Code | `run.system_prompt` and `run.developer_prompt` in `~/.config/muse/settings.json`; foreign personal rules `~/.claude/CLAUDE.md` and `$CODEX_HOME/AGENTS.md` unless `context.foreign_personal_rules` disables them |

OpenCode dedupes instruction paths by string, not by canonical target. On this Mac `~/.claude/CLAUDE.md` is a symlink to `~/.codex/AGENTS.md`, and `opencode.jsonc` lists `~/.codex/AGENTS.md`, so the same text loads twice.

### Base prompt

| Harness | Source |
| --- | --- |
| Codex | `~/.codex/models_cache.json`, per model under `model_messages` (`persistent_instructions`, `instructions_template` and related templates). Fallback: `https://raw.githubusercontent.com/openai/codex/rust-v<version>/codex-rs/models-manager/prompt.md` |
| OpenCode | `https://raw.githubusercontent.com/anomalyco/opencode/v<version>/packages/opencode/src/session/prompt/<name>.txt`, listed through `https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/session/prompt?ref=v<version>` |
| Others | Unavailable: the prompt exists only inside the binary. Detail text: "Closed source. Use Capture." |

### Capture redirects

| Harness | Redirect | Command |
| --- | --- | --- |
| Claude Code | env `ANTHROPIC_BASE_URL`, env `ANTHROPIC_API_KEY` placeholder | `claude -p hi` |
| Codex | `-c model_provider=skillshelf`, `-c model_providers.skillshelf.base_url=<url>/v1`, `wire_api="responses"`, `env_key` pointing at a placeholder variable, WebSockets off | `codex exec --skip-git-repo-check hi` |
| OpenCode | env `OPENCODE_CONFIG_CONTENT` adding a provider with `options.baseURL` and a placeholder `apiKey`, selected as the model | `opencode run hi` |
| Grok | env `GROK_CLI_CHAT_PROXY_BASE_URL` | `grok -p hi` |
| Muse Code | `--base-url` with a placeholder key | `muse exec --base-url <url> hi` |
| Cursor | Unavailable: the final prompt is assembled on Cursor's servers. | |
| Antigravity | Unavailable: custom endpoints need `GEMINI_API_KEY` and are ignored with Google sign-in. | |

The exact flags for each command are confirmed during implementation against the installed version. Built-in Codex provider ids are reserved, so the custom provider id is required. `OPENAI_BASE_URL` alone does not redirect Codex 0.164.0.

## Core (`SkillShelfCore`)

### Model

```swift
public enum PromptLayer: Sendable { case instructions, base, capture }

public enum PromptStatus: Sendable, Hashable {
    case present
    case missing
    case unavailable(String)
}

public struct PromptPart: Sendable, Identifiable, Hashable {
    public let harness: HarnessID
    public let layer: PromptLayer
    public let title: String
    public let source: PromptSource
    public let status: PromptStatus
    public let notes: [String]
}

public enum PromptSource: Sendable, Hashable {
    case file(path: String, key: String?)
    case remote(url: URL, cache: String)
    case capture(path: String)
    case none
}
```

`key` names the config key when the part is one value inside a TOML or JSON file.

### InstructionReader

`static func parts(layout: Layout, harness: HarnessID) -> [PromptPart]`, synchronous file I/O against the injectable home in `Layout`.

- Returns parts in the load order of the table above, including missing files so the user sees where a file would go.
- Expands Claude `@path` imports one level deep and OpenCode `instructions` globs.
- Adds the note "Same file as <other part>, loaded twice" when two present parts in one harness share a canonical target.
- Cursor returns one part with `unavailable("Managed in Cursor Settings > Rules")`.

Config parsing:
- `TOMLKeys`: generalizes the line parser in `PluginReaders.grokCompat` into a reader for `section.key` string, multi-line string and bool values. `grokCompat` moves onto it.
- `JSONC`: strips `//` and `/* */` comments and trailing commas, then uses `JSONSerialization`.

### BasePromptReader

- Version: `<tool> --version` through `CommandRunning`, first semver match.
- Codex: one part per model in `models_cache.json`, titled with the model slug. The model set by `model` in `config.toml` gets the note "Configured model" and sorts first. If the cache is missing or unreadable, falls back to the GitHub `prompt.md` for the version.
- OpenCode: lists the prompt directory through the contents API, then fetches each file.
- Remote files are cached at `~/Library/Caches/SkillShelf/prompts/<harness>/<version>/<file>`. A cached file is never refetched; the version is part of the path.
- Network goes through a `PromptFetching` protocol so tests inject a stub.

### PromptCapture

An `actor`, separate from `Mutator`. One capture at a time.

1. Binds a listener to 127.0.0.1 on a free port. Never any other interface.
2. Creates an empty temp directory as the working directory.
3. Starts the harness with the redirect from the table, the login PATH, stdin closed, its own process group, and a 60 s timeout. Placeholder credentials are used wherever the harness accepts them, so the user's real tokens are not sent to the listener; parts made this way carry the note "Placeholder auth: account-specific text may differ". Grok was verified only with its stored OAuth login; if a placeholder fails there, the listener still discards headers unread.
4. For each request: reads the body, discards all headers, records method, path and body, and answers `400` with a JSON error body the client treats as fatal. Nothing is forwarded.
5. Stops when the process exits or the timeout fires, then terminates the process group and removes the temp directory.
6. Writes `~/Library/Application Support/SkillShelf/captures/<harness>/<ISO8601 timestamp>.json` holding harness, version, command, and the recorded requests. The largest request body is marked as the main prompt; the others are helper calls.

`CaptureParser` turns a recorded body into sections:
- Anthropic `messages` format: `system` (string or blocks), `tools`, `messages`.
- OpenAI `responses` format: `instructions`, `input` items by role, `tools`.
- Anything else: pretty-printed raw JSON.

## App (`SkillShelf`)

- `SidebarItem.prompts(HarnessID)`. A "System prompts" section below "Harnesses", one row per installed harness, badged with the number of present parts.
- Middle column: `PromptPartList`, grouped by layer under "Instructions", "Base prompt @ <version>" and "Capture". Rows show title, status icon (present; missing in grey; unavailable with the reason as help text) and notes. The Capture header holds "Capture now" and a progress indicator. Captures list newest first. The search field filters titles and text.
- Detail: `PromptTextView` with the existing MarkdownUI theme.
  - Markdown files render as markdown.
  - Config parts show only their key's value, as a code block.
  - Base prompts render as markdown with a source line (cache path or URL).
  - Captures render as `## System`, `## Tools (<n>)` with name and first description line per tool and the full JSON in a code block, `## Messages`, then `## Helper calls`.
  - Actions: Reveal in Finder, Open, Copy text.
- Loading: instruction parts load during the existing scan (⌘R and on activation). Base prompts load when the harness's prompt row is selected, in a task keyed by harness and version, so the network is touched only in that view. Capture runs only from the button.
- `AppModel` holds the prompt parts in its snapshot and reuses the generation check.

## Errors

Shown in the part row and the detail pane, not as alerts.

| Case | Shown |
| --- | --- |
| Version command fails | Base layer `unavailable("Could not read version: <first output line>")` |
| GitHub fetch fails (offline, rate limit, 404 for the tag) | Error text and Retry; a cached copy if present |
| Harness not on the login PATH | Capture `unavailable("Not installed")` |
| No request within 60 s | "The harness made no request to the capture endpoint. Its redirect setting may have changed in <version>." |
| Unknown body format | Pretty-printed JSON |
| Capture cancelled or timed out | Process group terminated, temp directory removed |

## Tests

Swift Testing with temp-home fixtures. No real harness is started.

- `InstructionReader`: load order per harness; missing parts; Codex TOML keys including multi-line strings; OpenCode JSONC with comments and trailing commas; Muse settings keys; the duplicate note for the OpenCode symlink case.
- `BasePromptReader`: `models_cache.json` parsing and configured-model ordering; GitHub URLs from a version; cache hit makes no fetch call.
- `PromptCapture`: launch spec per harness (argv, env, cwd); `CaptureParser` for both formats and the fallback; main request selection; saved files contain no header data.

## Docs

Add a "System prompts" section to `docs/plan.md` summarizing the tables above, and one README line.

## Risks

- Paths, config keys, cache formats and redirect variables change between releases. The version is shown on every base and capture part so stale behavior is visible.
- Codex `models_cache.json` reflects server-delivered templates and can differ from the release's bundled prompt.
- Captures miss provider-side additions and depend on session state (skills, MCP servers, hooks).
- Placeholder auth can differ from subscription auth in small ways.
