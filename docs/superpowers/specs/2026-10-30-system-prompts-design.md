# System prompts view

## Goal

Show, read-only, what each installed harness puts in front of the model before the user's first message. Three layers per harness:

1. Instructions: global user files and config keys the harness reads.
2. Base prompt: the vendor's built-in prompt for the installed version.
3. Capture: the request body the harness sends, recorded on a loopback listener inside a network sandbox.

Out of scope: editing any file, project-level instructions, comparing harnesses or versions, extracting strings from binaries, provider-side text that never leaves the vendor's servers, full-text search of prompt bodies.

## Facts this design relies on

Verified on this Mac on 2026-10-30. Versions: Claude Code 2.1.312, Codex 0.164.0, Cursor 3.26.16, OpenCode 1.19.5, Grok 1.0.70, Antigravity CLI (`agy`) 1.4.9, Muse Code 1.4.14.

### Instructions

Layer 1 lists the sources a harness reads, in its documented order. It does not claim to reproduce the exact request; Capture is the ground truth. Each part is either always loaded or conditional, and conditional parts say when they apply.

| Harness | Always loaded | Conditional |
| --- | --- | --- |
| Claude Code | `~/.claude/CLAUDE.md` and its `@path` imports, recursively up to 4 hops with a cycle guard; `~/.claude/rules/**/*.md` without `paths` frontmatter | Rules with `paths` frontmatter ("loads when a matching file is read"); the output style named by `outputStyle` in `~/.claude/settings.json`: a user file in `~/.claude/output-styles/` is shown, a built-in style is `unavailable("Built-in style")`. Plugin-forced styles are not detected. |
| Codex | `~/.codex/AGENTS.override.md` if non-empty, else `~/.codex/AGENTS.md` (`$CODEX_HOME` overrides `~/.codex`); `config.toml` keys `instructions`, `developer_instructions` | `model_instructions_file` ("replaces the base prompt") |
| Cursor | Unavailable: user rules come from Cursor's server-side knowledge base. | |
| OpenCode | Global config merged in order `config.json`, `opencode.json`, `opencode.jsonc` under `~/.config/opencode`. `~/.config/opencode/AGENTS.md`, else `~/.claude/CLAUDE.md`; every `instructions` entry (files, globs, URLs) | Agent definitions found recursively in `~/.config/opencode/agents/**/*.md` and legacy `agent/**/*.md`, plus `agent.<name>.prompt`: shown in their own group, each noted "replaces the base prompt when this agent is selected". The agent named by `default_agent` is marked active. Without `default_agent`, none is marked and the group notes "OpenCode uses the first enabled primary agent. Capture shows which." |
| Grok | Every matching named file under `$GROK_HOME` (default `~/.grok`): `Agents.md`, `Claude.md`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENT.md`, `AGENTS.md`, deduplicated by file identity (case-insensitive filesystem); the same named files in `~/.claude` and `~/.cursor`; rule dirs `$GROK_HOME/rules`, `~/.claude/rules`, `~/.cursor/rules`, then `[paths].extra_rule_dirs`, each sorted by name. Each compat source honors its own `[compat.claude]` and `[compat.cursor]` switches as documented in `~/.grok/docs/user-guide/12-project-rules.md`. | |
| Antigravity | `~/.gemini/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.gemini/config/AGENTS.md`, `~/.gemini/config/GEMINI.md`; rules in `~/.gemini/config/rules/*.md` and `~/.gemini/antigravity-cli/rules/*.md` with `trigger: always_on` | Rules with any other `trigger` |
| Muse Code | `run.system_prompt` and `run.developer_prompt` in `~/.config/muse/settings.json`; foreign personal rules `~/.claude/CLAUDE.md` and `$CODEX_HOME/AGENTS.md` unless `context.foreign_personal_rules` disables them | |

On this Mac `~/.claude/CLAUDE.md` is a symlink to `~/.codex/AGENTS.md`, and OpenCode's `instructions` lists `~/.codex/AGENTS.md`. OpenCode dedupes by path string, so the same text loads twice. The reader flags this.

### Base prompt

| Harness | Source |
| --- | --- |
| Codex | `~/.codex/models_cache.json`, per model under `model_messages` (`persistent_instructions`, `instructions_template` and related templates). Fallback: `https://raw.githubusercontent.com/openai/codex/rust-v<version>/codex-rs/models-manager/prompt.md` |
| OpenCode | `https://raw.githubusercontent.com/anomalyco/opencode/v<version>/packages/opencode/src/session/prompt/<name>.txt`, listed through `https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/session/prompt?ref=v<version>` |
| Others | `unavailable("Closed source. Use Capture.")` |

### Capture adapters

| Harness | Redirect and credential | Command | Unix socket exceptions | Session history | Status |
| --- | --- | --- | --- | --- | --- |
| Claude Code | env `ANTHROPIC_BASE_URL`, placeholder `ANTHROPIC_API_KEY` | `claude -p --no-session-persistence <sentinel>` | None | Persistence disabled; after process exit, remove only the project directory named from this run's unique temporary cwd, including its canonical path spelling | Verified on this Mac with a placeholder; main request found, 12 tools |
| Codex | `-c model_provider=skillshelf`, `-c model_providers.skillshelf.base_url=<url>/v1`, `wire_api="responses"`, `env_key` naming a placeholder variable, WebSockets off | `codex exec --ephemeral --skip-git-repo-check <sentinel>` | None | `--ephemeral` disables session files; no shared history paths are selected for cleanup | Verified on this Mac with a placeholder; main request found, 4 tools in `input` items of type `additional_tools` on 0.164.0 |
| OpenCode | env `OPENCODE_CONFIG_CONTENT` adding provider `skillshelf` with `options.baseURL` and a placeholder `apiKey`, selected as the model | `opencode run <sentinel>` | None | `run --help` has no no-persistence flag; env `OPENCODE_DB=:memory:` keeps the capture session in memory, leaving the user's shared SQLite history untouched | Verified on this Mac with a placeholder; main request found, 10 tools |
| Grok | Tried env `GROK_CLI_CHAT_PROXY_BASE_URL=<url>/v1`, placeholder `XAI_API_KEY`; `GROK_AUTH_PATH=/dev/null` excludes stored login | `grok -p <sentinel>` | None | Disabled | Disabled, `unavailable("Requires real login")`; no request within 60 s with the placeholder, no stderr diagnostics |
| Muse Code | `--base-url`; installed 1.4.14 `exec --help` exposes `--api-key-stdin`, no key environment variable | `muse exec --base-url <url> <sentinel>` | None | Disabled | Disabled, `unavailable("Placeholder key needs --api-key-stdin, not supported yet")`; CaptureProcess supplies null stdin |
| Cursor | | | None | Disabled | `unavailable("Prompt is assembled on Cursor's servers")` |
| Antigravity | | | None | Disabled | `unavailable("No verified local redirect")` |

Each adapter's flags are confirmed against the installed version during implementation. An adapter is enabled only after it has captured a request with a placeholder credential on this Mac.

## Core (`SkillShelfCore`)

### Model

```swift
public enum PromptLayer: Sendable { case instructions, agentDefinitions, base, capture }

public enum PromptStatus: Sendable, Hashable {
    case present
    case missing
    case unavailable(String)
}

public enum PromptSource: Sendable, Hashable {
    case file(path: String, key: String?)
    case remote(url: URL, cache: String?)
    case capture(path: String)
    case none
}

public struct PromptPart: Sendable, Identifiable, Hashable {
    public let id: String
    public let harness: HarnessID
    public let layer: PromptLayer
    public let title: String
    public let source: PromptSource
    public let status: PromptStatus
    public let version: String?
    public let notes: [String]
}
```

`id` is `<harness>/<layer>/<source identity>` (path plus key, URL, or capture file), stable across rescans. `key` names the config key when the part is one value inside a TOML or JSON file.

Text is loaded separately: `PromptContent.load(_ part: PromptPart, fetcher: PromptFetching) async -> PromptText`, a `@concurrent` function returning either text with a format (markdown, code, capture sections) or an error. Same pattern as `SkillFileView.load`.

### InstructionReader

`static func parts(layout: Layout, harness: HarnessID) -> [PromptPart]`. Synchronous local file reads against the injectable home in `Layout`; never touches the network. Remote `instructions` URLs become `.remote` parts loaded on selection.

- Missing files are included with status `missing`, so the user sees where a file would go.
- When two present parts in one harness share a canonical target, both get the note "Same file as <other part>, loaded twice".
- Cursor returns one part with `unavailable("Managed in Cursor Settings > Rules")`.

Config parsing, scoped lexical readers with no new dependency:
- `TOMLKeys`: reads `section.key` values of type basic and literal string, multi-line string with escapes, bool, and array of strings. `PluginReaders.grokCompat` moves onto it.
- `JSONC`: removes `//` and `/* */` comments and trailing commas while respecting string literals and escapes, then uses `JSONSerialization`.
- OpenCode substitutions, applied to the raw text before JSONC parsing as OpenCode does: `{file:<path>}` is replaced by that file's contents, with the path resolved relative to the config file's directory and `~` expanded; the resulting part's source is the referenced file, noted "via {file:} in <config file>". `{env:<VAR>}` is left unresolved and noted "set from the environment at runtime".

### BasePromptReader

- Version: `<tool> --version` through `CommandRunning`, first semver match.
- Codex: one part per model in `models_cache.json`, titled with the model slug. The model named by `model` in `config.toml` gets the note "Configured model" and sorts first. If the cache is missing or unreadable, falls back to GitHub `prompt.md` for the version.
- OpenCode: lists the prompt directory through the contents API, one part per file.
- Fetched files are cached at `~/Library/Caches/SkillShelf/prompts/<harness>/<version>/<file>`. A cached file is never refetched; the version is in the path.
- Network goes through a `PromptFetching` protocol so tests inject a stub.

### PromptCapture

Three units:

- `CaptureListener`: HTTP/1.1 server bound to 127.0.0.1 on a free port through `NWListener` with a required local endpoint. Never any other interface.
- `CaptureProcess` protocol, with a `posix_spawn` implementation: launches an executable with explicit argv, env and cwd in its own process group; exposes `terminate()` (SIGTERM to the group, SIGKILL after 3 s) and an awaitable exit. Tests inject a fake. `CommandRunning` is unchanged.
- `PromptCapture` actor: orchestrates one capture.

Run:

1. Busy check: a `isRunning` flag is set before the first `await`; a second request while running returns `.busy`.
2. Sentinel: a user message `SKILLSHELF_CAPTURE_<UUID>`.
3. Sandbox: the harness runs as `/usr/bin/sandbox-exec -p <profile> <harness> ...` with this profile:

   ```scheme
   (version 1)
   (allow default)
   (deny network*)
   (allow network-outbound (remote ip "localhost:<port>"))
   ```

   The only allowed connection is outbound to the capture port. That also blocks other localhost services, such as local proxies, HTTP MCP servers and bridges, which could relay traffic off the Mac, and every Unix domain socket. The base URL uses the literal `http://127.0.0.1:<port>`, so no name resolution happens. Child processes (hooks, MCP servers, plugins) inherit the profile. If an adapter cannot reach the listener without a specific Unix socket, that socket's exact path is allowed with `(remote unix-socket (path-literal "<path>"))` for that adapter only, and the spec's adapter table records it. If `sandbox-exec` is missing or the profile fails to apply, the capture fails with "Network sandbox unavailable" and nothing runs.
4. Environment: the login PATH and home from the existing runner, minus every credential and proxy variable (`ANTHROPIC_*`, `OPENAI_*`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `GOOGLE_*`, `XAI_*`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` and their lowercase forms), plus the adapter's redirect and placeholder variables. The user's own config files are used as they are, so hooks, local MCP servers, skills and plugins contribute what they normally would. Remote MCP servers, HTTP MCP servers on other localhost ports and any other connection fail inside the sandbox, and the capture notes which MCP servers failed when the harness reports it.
5. cwd: a new empty temp directory.
6. Listener behavior per request:
   - Limits: 64 KB of headers, 32 MB of body per request, 64 MB of bodies in total, 8 concurrent connections, 30 requests. Over a limit, the connection is closed and the capture notes it.
   - Framing: `Content-Length` and `chunked`. Headers are parsed in memory for framing only and never stored or logged.
   - `Content-Encoding` other than identity: the body is stored base64-encoded with a "compressed body (<encoding>), not decoded" note.
   - WebSocket upgrades are refused.
   - Only `POST` requests are recorded. Other methods get the same response and are dropped, because local tools such as T3 Code probe every new loopback port with `GET /`.
   - Response: `400` with a body in the adapter's error format, `{"type":"error","error":{"type":"invalid_request_error","message":"SkillShelf capture"}}` for Anthropic and `{"error":{"type":"invalid_request_error","code":"skillshelf_capture","message":"SkillShelf capture"}}` for OpenAI-style. The message avoids words that clients treat as retryable.
7. Stop: as soon as a request body contains the sentinel and a non-empty tools list, the process group is terminated. Otherwise the capture stops when the process exits or after 60 s.
8. Cleanup, always awaited, also on cancellation through `withTaskCancellationHandler`: terminate the process group, wait for exit, close the listener and every connection, remove the temp directory.
9. Save to `~/Library/Application Support/SkillShelf/captures/<harness>/<ISO8601 timestamp>.json`. Directories are created `0700`, files `0600`. The file holds harness, version, adapter, command without placeholder values, date, notes, each request's method, path, body and optional `bodyEncoding`, and optional `diagnostics` containing the last 4 KB of harness stderr. The sentinel is stored in notes as `"sentinel: <value>"` so main request selection can be recomputed on load.

Main request selection: the first request containing the sentinel and a non-empty tools list. If none has tools, the first containing the sentinel, labeled "Main request: best guess". If no request contains the sentinel, all requests are shown and the main request is "unknown". Every other request is a helper call.

`CaptureParser` turns a body into sections:
- Anthropic `messages`: `system` (string or blocks), `tools`, `messages`.
- OpenAI `responses`: `instructions`, `input` items by role, `tools`.
- OpenAI Chat Completions: `messages` with role `system` or `developer` go to System in request order; other roles go to Messages. Function tool names and descriptions come from `tools[].function`, with full tool JSON preserved.
- Anything else: pretty-printed raw JSON.

## App (`SkillShelf`)

- `SidebarItem.prompts(HarnessID)`. A "System prompts" section below "Harnesses", one row per installed harness, badged with the number of present parts.
- Middle column: `PromptPartList`, grouped under "Instructions", "Agent definitions" (OpenCode only), "Base prompt @ <version>" and "Capture". Rows show title, status icon (present; missing in grey; unavailable with the reason as help text) and notes. The Capture header holds "Capture now" and a progress indicator. Captures list newest first. The search field filters part titles.
- Detail: `PromptTextView` using the existing MarkdownUI theme. Text loads through `PromptContent.load` off the main actor.
  - Markdown files render as markdown.
  - Config parts show only their key's value, as a code block.
  - Base prompts render as markdown with a source line (cache path or URL).
  - Captures render as a header (version, adapter, notes such as failed MCP servers or placeholder auth), `## System`, `## Tools (<n>)` with name and first description line per tool and the full JSON in a code block, `## Messages`, then `## Helper calls`.
  - Actions: Reveal in Finder, Open, Copy text.
- State in `AppModel`, separate from the skills snapshot:
  - `promptParts: [HarnessID: [PromptPart]]` for instructions, rebuilt during the regular scan and committed only if its generation is current.
  - `baseParts: [HarnessID: BaseState]`, keyed by version, loaded when a prompts row is selected and kept across refreshes.
  - `captures: [HarnessID: [PromptPart]]`, read from the captures directory on selection and after each capture.
  - `promptSelection: PromptPart.ID?`, separate from the skill `selection`, kept across refreshes while its id still exists.

## Errors

Shown in the part row and the detail pane, not as alerts.

| Case | Shown |
| --- | --- |
| Version command fails | Base layer `unavailable("Could not read version: <first output line>")` |
| Fetch fails (offline, rate limit, 404 for the tag) | Error text and Retry; a cached copy if present |
| Harness not on the login PATH | Capture `unavailable("Not installed")` |
| Network sandbox cannot be applied | "Network sandbox unavailable. Capture did not run." |
| No request within 60 s | "The harness made no request to the capture endpoint. Its redirect setting may have changed in <version>." |
| A request limit is exceeded | Capture saved with a note naming the limit |
| Unknown body format | Pretty-printed JSON |
| Capture already running | Button disabled |
| Cancelled or timed out | Process group terminated, listener closed, temp directory removed |

## Tests

Swift Testing with temp-home fixtures.

- `InstructionReader`: per-harness order; missing parts; Claude imports with depth limit and a cycle; Claude conditional rules; Grok multiple named files with a case-insensitive duplicate, compat switches and a custom `$GROK_HOME`; OpenCode config merge order, recursive agent discovery, active agent with and without `default_agent`, `{file:}` and `{env:}` substitutions; Muse settings keys; the duplicate note for the OpenCode symlink case.
- `TOMLKeys` and `JSONC`: multi-line strings, escapes, string arrays, comment markers and URLs inside strings, trailing commas.
- `BasePromptReader`: `models_cache.json` parsing and configured-model ordering; GitHub URLs from a version; a cache hit makes no fetch call.
- `CaptureParser`: Anthropic, OpenAI Responses, Chat Completions and the fallback; main request selection with and without tools and sentinel.
- `PromptCapture` lifecycle with a real listener and a fake client script (`/bin/sh` running `curl` against the listener, then sleeping): request recorded; process group terminated once the sentinel request arrives; temp directory removed; saved file has no header data and `0600` permissions; cancellation cleans up; a second capture while busy returns `.busy`; limits close oversized requests.
- Sandbox: inside the profile, a connection to the listener succeeds; a connection to a second local listener on another port, a non-loopback address and a Unix socket each fail with `EPERM`. Covered for `curl`, a child of a child process, and a URLSession client.

No real harness is started in tests.

## Docs

Add a "System prompts" section to `docs/plan.md` summarizing the tables above, and one README line.

## Risks

- Paths, config keys, cache formats and redirect variables change between releases. The version is shown on every base and capture part so stale behavior is visible.
- `sandbox-exec` is deprecated by Apple but still ships. If it disappears, Capture fails closed.
- Codex `models_cache.json` reflects server-delivered templates and can differ from the release's bundled prompt.
- Captures miss provider-side additions and anything from remote MCP servers.
- Hooks and stdio MCP servers run during a capture with the user's config. Their local side effects happen as in a normal session.
- Session-persistence controls depend on the installed harness version. Capture disables conversation history, but shared diagnostic logs, caches, and hook or MCP side effects can still retain run metadata. Shared files are never edited or deleted to remove that metadata.
- Blocking Unix sockets can break a hook or MCP server that needs one; the capture then lacks its text.
- Placeholder auth can differ from subscription auth in small ways.
