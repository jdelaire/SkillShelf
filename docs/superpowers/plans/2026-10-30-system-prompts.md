# System Prompts View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only "System prompts" view showing, per installed harness, its instruction sources, its vendor base prompt, and a sandboxed capture of the request it sends.

**Architecture:** Pure readers in `SkillShelfCore` (`InstructionReader`, `BasePromptReader`, `CaptureParser`, `PromptContent`) produce `PromptPart` values. `PromptCapture` (actor) runs a harness under `sandbox-exec` against `CaptureListener` on 127.0.0.1 and saves the recorded bodies. The app adds a sidebar section, a part list and a text view, with prompt state kept separate from the skills snapshot.

**Tech Stack:** Swift 6.2, SwiftPM, SwiftUI, MarkdownUI, Network.framework, Swift Testing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-30-system-prompts-design.md`. Read it before any task. Tables there (paths, adapters, errors) are normative and are not repeated here.

## Global Constraints

- macOS 15+, Apple silicon. `swift test` must pass after every task.
- No new package dependencies. No code comments (user rule).
- Read-only: no code path writes to any harness file or config. The only writes are `~/Library/Caches/SkillShelf/prompts/...` and `~/Library/Application Support/SkillShelf/captures/...`.
- Capture dirs `0700`, capture files `0600`. HTTP headers are never stored or logged.
- Listener binds 127.0.0.1 only. Sandbox profile exactly as in the spec, with the port substituted. Capture fails closed if the sandbox cannot be applied.
- Capture limits: 64 KB headers, 32 MB body per request, 64 MB of bodies in total, 8 concurrent connections, 30 requests, 60 s timeout, SIGTERM then SIGKILL after 3 s. Harness stdout and stderr: last 256 KB each kept in memory.
- Scan cost: `InstructionReader` reads each canonical file at most once per scan, reads rule files only up to their first 4 KB (frontmatter), skips import parsing in files over 1 MB, and stops enumerating a rule tree after 500 files with a note.
- Sentinel: `SKILLSHELF_CAPTURE_<UUID>`.
- Tests use temp homes (`Fixture`) and never start a real harness.
- Tests cover meaningful logic only (user rule).

## Review Focus

1. A harness config file that exists but is malformed (bad TOML, broken JSONC): the reader must still list file parts and skip only the keys it cannot read, never crash or drop the harness.
2. A Claude `@import` or OpenCode `{file:}` that points to a missing file or outside the home: shown as a `missing` part with its path, no crash.
3. Capture while the harness is not logged in or the placeholder key is rejected before any request: the 60 s message appears and no process or temp dir remains.
4. Rescan (⌘R or app activation) while a prompt part is selected and while a capture is running: selection and capture survive; the capture result appears when done.
5. Huge prompt files (several MB, such as a long AGENTS.md or capture): text loads off the main actor; the list stays responsive.

Tests for these live in Tasks 2, 3, 8, 10 and 12.

Spec deviation adopted here (update the spec's Model section in Task 2): `PromptSource.remote(url: URL, cache: String?)`. Base prompts carry their version cache path; instruction URLs have `cache: nil`, are fetched on every load and never written to disk.

---

### Task 1: Config readers

**Files:**
- Create: `Sources/SkillShelfCore/ConfigReaders.swift`
- Modify: `Sources/SkillShelfCore/PluginReaders.swift:101-119` (`grokCompat` uses `TOMLKeys`)
- Test: `Tests/SkillShelfCoreTests/ConfigReaderTests.swift`

**Interfaces:**
- Produces:
  - `public enum TOMLValue: Sendable, Equatable { case string(String), bool(Bool), strings([String]) }`
  - `public struct TOMLKeys: Sendable { public init(_ text: String); public subscript(_ key: String) -> TOMLValue? { get }; public func string(_ key: String) -> String?; public func bool(_ key: String) -> Bool?; public func strings(_ key: String) -> [String]?; public let sections: Set<String> }`. Keys are dotted: top-level `model`, section `compat.claude.skills`.
  - `public enum JSONC { public static func strip(_ text: String) -> String; public static func object(_ text: String) -> [String: Any]? }`

- [ ] **Step 1: Write failing tests**

```swift
@Test func tomlReadsStringsBoolsArraysAndMultiline() {
    let toml = TOMLKeys("""
    model = "gpt-6.1-sol"
    developer_instructions = \"\"\"
    Line one
    Say \\"hi\\"\"\"\"
    literal = 'C:\\path'
    [compat.claude]
    skills = false
    [paths]
    extra_rule_dirs = ["~/rules", "/opt/r#x"] # comment
    """)
    #expect(toml.string("model") == "gpt-6.1-sol")
    #expect(toml.string("developer_instructions") == "Line one\nSay \"hi\"")
    #expect(toml.string("literal") == "C:\\path")
    #expect(toml.bool("compat.claude.skills") == false)
    #expect(toml.strings("paths.extra_rule_dirs") == ["~/rules", "/opt/r#x"])
    #expect(toml.sections.contains("compat.claude"))
}

@Test func tomlReadsMultilineArraysWithComments() {
    let toml = TOMLKeys("""
    [paths]
    extra_rule_dirs = [
      "~/a", # first
      '~/b',
    ]
    after = true
    """)
    #expect(toml.strings("paths.extra_rule_dirs") == ["~/a", "~/b"])
    #expect(toml.bool("paths.after") == true)
}

@Test func tomlSkipsMalformedLinesKeepsRest() {
    let toml = TOMLKeys("model = \"a\"\nbroken = [\"x\"\nok = true")
    #expect(toml.string("model") == "a")
    #expect(toml.bool("ok") == true)
}

@Test func jsoncKeepsCommentMarkersInsideStrings() {
    let object = JSONC.object("""
    {
      // comment
      "instructions": ["https://x.dev/a.md", "/* not a comment */"], /* block */
      "agent": { "a": { "prompt": "x // y", }, },
    }
    """)
    #expect(object?["instructions"] as? [String] == ["https://x.dev/a.md", "/* not a comment */"])
    #expect(((object?["agent"] as? [String: Any])?["a"] as? [String: Any])?["prompt"] as? String == "x // y")
}
```

Keep the existing `PluginReaders.grokCompat` tests green (they cover the migration).

- [ ] **Step 2: Run `swift test --filter ConfigReaderTests`.** Expected: FAIL, `TOMLKeys` undefined.
- [ ] **Step 3: Implement** a line-oriented lexer: section headers, `key = value`, basic strings with escapes (`\"`, `\\`, `\n`, `\t`, `\uXXXX`), literal strings, `"""` multi-line basic strings (first newline trimmed), booleans, string arrays spanning one or more lines with comments and a trailing comma, `#` comments outside strings. Unparseable lines are skipped. `JSONC.strip` is a character state machine (in string / escape / line comment / block comment) that also drops a `,` followed only by whitespace and `}` or `]`. Rewrite `grokCompat` on `TOMLKeys`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add TOML and JSONC readers`.

---

### Task 2: Prompt model and InstructionReader (Claude, Codex, Cursor, Antigravity, Muse)

**Files:**
- Create: `Sources/SkillShelfCore/Prompts.swift` (model), `Sources/SkillShelfCore/InstructionReader.swift` (dispatch, shared helpers, Codex, Cursor, Antigravity, Muse), `Sources/SkillShelfCore/ClaudeInstructions.swift`
- Modify: `Tests/SkillShelfCoreTests/Fixture.swift` (no change expected; reuse `write`/`link`)
- Test: `Tests/SkillShelfCoreTests/InstructionReaderTests.swift`

**Interfaces:**
- Consumes: `TOMLKeys`, `JSONC`, `Frontmatter.parse`, `Layout`, `Paths.canonical`.
- Produces:
  - `PromptLayer`, `PromptStatus`, `PromptSource`, `PromptPart` exactly as in the spec's Model section, plus `public init(harness:layer:title:source:status:version:notes:)` that derives `id` as `"\(harness.rawValue)/\(layer)/\(identity)"`, where identity is `path` + `#key` if any, the URL string, the capture path, or the title for `.none`.
  - `public enum InstructionReader { public static func parts(layout: Layout, harness: HarnessID, environment: [String: String] = ProcessInfo.processInfo.environment, files: InstructionFiles = InstructionFiles()) -> [PromptPart] }`. `environment` supplies `CODEX_HOME` and `GROK_HOME`.
  - `public final class InstructionFiles` (not `Sendable`; one instance per scan, used on one task): `func text(_ path: String) -> String?` reads each canonical path once and memoizes; `func head(_ path: String, bytes: Int = 4096) -> String?` for frontmatter; internal `var reads: Int` for tests. Applies the Global Constraints scan limits.
  - Internal helper `static func file(_ path: String, harness: HarnessID, layer: PromptLayer, layout: Layout, notes: [String] = []) -> PromptPart` (status `present` if readable, else `missing`; title `layout.display(path)`).
  - Internal `static func markDuplicates(_ parts: [PromptPart]) -> [PromptPart]` adding `"Same file as \(other.title), loaded twice"` to every present part sharing a canonical target with another.
  - Config key parts are titled `"<file name> › <key>"`, source `.file(path:key:)`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func claudeImportsRecurseFourHopsAndStopAtCycles() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".claude/CLAUDE.md", "See @a.md")
    try f.write(".claude/a.md", "@b.md"); try f.write(".claude/b.md", "@c.md")
    try f.write(".claude/c.md", "@d.md"); try f.write(".claude/d.md", "@e.md @CLAUDE.md")
    try f.write(".claude/e.md", "too deep")
    let paths = InstructionReader.parts(layout: f.layout, harness: .claude).compactMap(\.filePath)
    #expect(paths.prefix(5) == ["CLAUDE.md", "a.md", "b.md", "c.md", "d.md"].map { f.layout.path(".claude/\($0)") })
    #expect(!paths.contains(f.layout.path(".claude/e.md")))
    #expect(paths.filter { $0 == f.layout.path(".claude/CLAUDE.md") }.count == 1)
}

@Test func claudeMissingImportIsListedAsMissing() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".claude/CLAUDE.md", "@gone.md")
    let gone = InstructionReader.parts(layout: f.layout, harness: .claude).first { $0.filePath == f.layout.path(".claude/gone.md") }
    #expect(gone?.status == .missing)
}

@Test func claudeRulesWithPathsAreConditionalAndOutputStyleResolves() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".claude/rules/always.md", "x")
    try f.write(".claude/rules/swift.md", "---\npaths: \"**/*.swift\"\n---\nx")
    try f.write(".claude/settings.json", #"{"outputStyle":"Explanatory"}"#)
    let parts = InstructionReader.parts(layout: f.layout, harness: .claude)
    #expect(parts.first { $0.filePath?.hasSuffix("swift.md") == true }?.notes.contains("Loads when a matching file is read") == true)
    #expect(parts.contains { $0.title == "Output style: Explanatory" && $0.status == .unavailable("Built-in style") })
}

@Test func codexOverrideWinsAndConfigKeysBecomeParts() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".codex/AGENTS.md", "base"); try f.write(".codex/AGENTS.override.md", "override")
    try f.write(".codex/config.toml", "developer_instructions = \"dev\"\nmodel_instructions_file = \"~/m.md\"")
    let parts = InstructionReader.parts(layout: f.layout, harness: .codex)
    #expect(parts.map(\.title).contains("~/.codex/AGENTS.override.md"))
    #expect(!parts.map(\.title).contains("~/.codex/AGENTS.md"))
    #expect(parts.contains { $0.title == "config.toml › developer_instructions" })
    #expect(parts.first { $0.title == "~/m.md" }?.notes.contains("Replaces the base prompt") == true)
}

@Test func malformedCodexConfigStillListsFiles() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".codex/AGENTS.md", "base"); try f.write(".codex/config.toml", "[[[ nope")
    #expect(InstructionReader.parts(layout: f.layout, harness: .codex).contains { $0.title == "~/.codex/AGENTS.md" })
}

@Test func sharedImportIsReadOncePerScan() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".claude/CLAUDE.md", "@shared.md"); try f.write(".claude/shared.md", "x")
    try f.write(".codex/AGENTS.md", "x"); try f.link(".gemini/GEMINI.md", to: "../.claude/shared.md")
    let files = InstructionFiles()
    for harness in [HarnessID.claude, .antigravity] { _ = InstructionReader.parts(layout: f.layout, harness: harness, files: files) }
    #expect(files.reads == 2)
}

@Test func largeRuleTreeStopsAt500() throws {
    let f = try Fixture(); defer { f.remove() }
    for i in 0..<510 { try f.write(".claude/rules/r\(i).md", "x") }
    let parts = InstructionReader.parts(layout: f.layout, harness: .claude)
    #expect(parts.filter { $0.filePath?.contains("/rules/") == true }.count == 500)
    #expect(parts.contains { $0.notes.contains("Stopped after 500 rule files") })
}

@Test func cursorIsUnavailable() throws {
    let f = try Fixture(); defer { f.remove() }
    #expect(InstructionReader.parts(layout: f.layout, harness: .cursor).map(\.status) == [.unavailable("Managed in Cursor Settings > Rules")])
}

@Test func antigravityRuleTriggersAndMuseForeignRules() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".gemini/config/rules/on.md", "---\ntrigger: always_on\n---\nx")
    try f.write(".gemini/config/rules/maybe.md", "---\ntrigger: model_decision\n---\nx")
    try f.write(".config/muse/settings.json", #"{"run":{"developer_prompt":"be brief"},"context":{"foreign_personal_rules":false}}"#)
    try f.write(".claude/CLAUDE.md", "x")
    let ag = InstructionReader.parts(layout: f.layout, harness: .antigravity)
    #expect(ag.first { $0.filePath?.hasSuffix("maybe.md") == true }?.notes.contains("Conditional: trigger model_decision") == true)
    let muse = InstructionReader.parts(layout: f.layout, harness: .muse)
    #expect(muse.contains { $0.title == "settings.json › run.developer_prompt" })
    #expect(!muse.contains { $0.filePath == f.layout.path(".claude/CLAUDE.md") })
}
```

Add `var filePath: String?` on `PromptPart` (path of a `.file` source) in `Prompts.swift`; tests use it. Update the spec's Model section to `case remote(url: URL, cache: String?)` in the same commit.

- [ ] **Step 2: Run `swift test --filter InstructionReaderTests`.** Expected: FAIL, types undefined.
- [ ] **Step 3: Implement** per the spec's Instructions table. Claude `@path`: tokens matching `(?<![\w`])@([~./\w-][^\s`]*)` outside fenced code blocks, resolved relative to the importing file, `~` expanded, depth ≤ 4 hops from `CLAUDE.md`, visited set by canonical path; imported parts get note `"Imported by <parent title>"`. Built-in output styles: any `outputStyle` value without a matching `~/.claude/output-styles/<name>.md` (case-insensitive) is `unavailable("Built-in style")`; `default` or unset adds no part. Codex `model_instructions_file` part gets note `"Replaces the base prompt"`. Antigravity rules with a trigger other than `always_on` get `"Conditional: trigger <value>"`. Every harness's result goes through `markDuplicates`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add prompt model and instruction reader`.

---

### Task 3: InstructionReader for Grok and OpenCode

**Files:**
- Create: `Sources/SkillShelfCore/GrokInstructions.swift`, `Sources/SkillShelfCore/OpenCodeInstructions.swift`
- Modify: `Sources/SkillShelfCore/InstructionReader.swift` (dispatch)
- Test: `Tests/SkillShelfCoreTests/InstructionReaderTests.swift`

**Interfaces:**
- Consumes: Task 1 and Task 2 interfaces.
- Produces: `.grok` and `.opencode` cases of `InstructionReader.parts`. OpenCode agent parts use layer `.agentDefinitions`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func grokLoadsEveryNamedFileOnceAndHonorsGrokHome() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("gh/AGENTS.md", "a"); try f.write("gh/CLAUDE.local.md", "b")
    try f.write("gh/rules/b.md", "x"); try f.write("gh/rules/a.md", "x")
    try f.write(".claude/CLAUDE.md", "c")
    try f.write("gh/config.toml", "[compat.claude]\nrules = false")
    let parts = InstructionReader.parts(layout: f.layout, harness: .grok, environment: ["GROK_HOME": f.layout.path("gh")])
    let present = parts.filter { $0.status == .present }.compactMap(\.filePath)
    #expect(present.contains(f.layout.path("gh/AGENTS.md")) && present.contains(f.layout.path("gh/CLAUDE.local.md")))
    #expect(present.filter { $0.hasPrefix(f.layout.path("gh/rules")) } == ["a.md", "b.md"].map { f.layout.path("gh/rules/\($0)") })
    #expect(present.contains(f.layout.path(".claude/CLAUDE.md")))
}

@Test func grokCaseInsensitiveDuplicateCountsOnce() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".grok/CLAUDE.md", "x")
    let present = InstructionReader.parts(layout: f.layout, harness: .grok).filter { $0.status == .present && $0.filePath?.hasPrefix(f.layout.path(".grok/")) == true }
    #expect(present.count == 1)
}

@Test func opencodeMergesConfigsAndExpandsFileSubstitution() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".config/opencode/config.json", #"{"instructions":["~/old.md"]}"#)
    try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["~/a.md","https://x.dev/r.md"],"agent":{"rev":{"prompt":"{file:./rev.txt}"}},"default_agent":"rev"}"#)
    try f.write(".config/opencode/rev.txt", "review prompt"); try f.write("a.md", "x")
    let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
    #expect(parts.contains { $0.filePath == f.layout.path("a.md") })
    #expect(!parts.contains { $0.filePath == f.layout.path("old.md") })
    #expect(parts.contains { if case .remote = $0.source { true } else { false } })
    let rev = try #require(parts.first { $0.layer == .agentDefinitions && $0.filePath == f.layout.path(".config/opencode/rev.txt") })
    #expect(rev.notes.contains("via {file:} in opencode.jsonc"))
    #expect(rev.notes.contains("Active agent"))
}

@Test func opencodeAgentsRecursiveAndNoActiveWithoutDefault() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".config/opencode/agents/team/deep.md", "x"); try f.write(".config/opencode/agent/old.md", "x")
    let agents = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .agentDefinitions }
    #expect(agents.filter { $0.filePath != nil }.count == 2)
    #expect(agents.filter { $0.source == .none }.map(\.status) == [.unavailable("No default_agent set")])
    #expect(!agents.contains { $0.notes.contains("Active agent") })
}

@Test func opencodeFileSubstitutionEscapesContentAndKeepsSiblings() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".config/opencode/multi.txt", "line \"one\"\nC:\\path")
    try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"a":{"prompt":"{file:./multi.txt}"},"b":{"prompt":"{file:./gone.txt}"}},"instructions":["~/x.md"]}"#)
    let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
    #expect(parts.contains { $0.filePath == f.layout.path(".config/opencode/multi.txt") && $0.status == .present })
    #expect(parts.contains { $0.filePath == f.layout.path(".config/opencode/gone.txt") && $0.status == .missing })
    #expect(parts.contains { $0.filePath == f.layout.path("x.md") })
}

@Test func opencodeFlagsSymlinkedDuplicate() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".codex/AGENTS.md", "x")
    try f.link(".claude/CLAUDE.md", to: "../.codex/AGENTS.md")
    try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["~/.codex/AGENTS.md"]}"#)
    let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
    #expect(parts.filter { $0.notes.contains { $0.hasSuffix("loaded twice") } }.count == 2)
}

@Test func opencodeEnvSubstitutionIsLeftUnresolved() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"x":{"prompt":"{env:MY_PROMPT}"}}}"#)
    let agent = InstructionReader.parts(layout: f.layout, harness: .opencode).first { $0.layer == .agentDefinitions }
    #expect(agent?.notes.contains("Set from the environment at runtime") == true)
}
```

- [ ] **Step 2: Run `swift test --filter InstructionReaderTests`.** Expected: new tests FAIL.
- [ ] **Step 3: Implement.** Grok: named files resolved under `$GROK_HOME` (default `~/.grok`), `~/.claude` and `~/.cursor`, each gated by its compat switch, deduplicated by `(st_dev, st_ino)`; rule dirs `$GROK_HOME/rules`, `~/.claude/rules`, `~/.cursor/rules`, then `paths.extra_rule_dirs`, sorted by name. Read the compat key names (`skills`, `rules`, `agents` and any named-file switch) from `~/.grok/docs/user-guide/12-project-rules.md` before coding and record them in a test. OpenCode: merge top-level keys of `config.json`, `opencode.json`, `opencode.jsonc` (later wins), applying `{file:}` substitution to each raw text first (path relative to that config file's dir, `~` expanded; the inserted content is JSON-string-escaped because the token sits inside a string literal; each substitution is recorded as `(key path, referenced file)` so the resulting part points to the file; a missing file inserts an empty string and gives a `missing` part); `AGENTS.md`, else `~/.claude/CLAUDE.md`; `instructions` entries: `http(s)` URLs become `.remote(url:, cache: nil)` parts, globs expand with `glob(3)`; agents from `agents/**/*.md`, `agent/**/*.md` and `agent.<name>.prompt`, each noted `"Replaces the base prompt when this agent is selected"`; `"Active agent"` only on the agent named by `default_agent`. Agent group without `default_agent` gets one `.none` part titled `"OpenCode uses the first enabled primary agent. Capture shows which."` with status `.unavailable("No default_agent set")`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Read Grok and OpenCode instruction sources`.

---

### Task 4: BasePromptReader

**Files:**
- Create: `Sources/SkillShelfCore/BasePromptReader.swift`
- Test: `Tests/SkillShelfCoreTests/BasePromptReaderTests.swift`

**Interfaces:**
- Consumes: `CommandRunning`, `TOMLKeys`, `PromptPart`.
- Produces:
  - `public protocol PromptFetching: Sendable { func data(from url: URL) async throws -> Data }` and `public struct URLSessionFetcher: PromptFetching`.
  - `public struct BasePrompts: Sendable { public let version: String?; public let parts: [PromptPart] }`
  - `public enum BasePromptReader { @concurrent public static func read(harness: HarnessID, layout: Layout, runner: any CommandRunning, fetcher: any PromptFetching, cacheRoot: String) async -> BasePrompts; public static func version(from output: String) -> String?; public static func openCodeListURL(version: String) -> URL; public static func openCodeFileURL(version: String, name: String) -> URL; public static func codexFallbackURL(version: String) -> URL; public static func cachePath(cacheRoot: String, harness: HarnessID, version: String, file: String) -> String }`
  - Default `cacheRoot`: `~/Library/Caches/SkillShelf/prompts`.
  - Codex parts: source `.file(path: <models_cache.json>, key: "models.<slug>")`, title = slug, note `"Configured model"` on the `model` from `config.toml`, sorted first. OpenCode parts: source `.remote(url: openCodeFileURL, cache: cachePath(...))`, title = file name. A failed listing yields one `.none` part with `.unavailable("Could not list prompts: <error description>")`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func versionParsesFirstSemver() {
    #expect(BasePromptReader.version(from: "codex-cli 0.164.0\n") == "0.164.0")
    #expect(BasePromptReader.version(from: "2.1.312 (Claude Code)") == "2.1.312")
}

@Test func urlsArePinnedToVersion() {
    #expect(BasePromptReader.openCodeFileURL(version: "1.19.5", name: "codex.txt").absoluteString == "https://raw.githubusercontent.com/anomalyco/opencode/v1.19.5/packages/opencode/src/session/prompt/codex.txt")
    #expect(BasePromptReader.openCodeListURL(version: "1.19.5").absoluteString == "https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/session/prompt?ref=v1.19.5")
    #expect(BasePromptReader.codexFallbackURL(version: "0.164.0").absoluteString == "https://raw.githubusercontent.com/openai/codex/rust-v0.164.0/codex-rs/models-manager/prompt.md")
}

@Test func codexModelsComeFromCacheWithConfiguredFirst() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".codex/models_cache.json", #"{"models":[{"slug":"a","model_messages":{"persistent_instructions":"p"}},{"slug":"b","model_messages":{"instructions_template":"t"}}]}"#)
    try f.write(".codex/config.toml", "model = \"b\"")
    let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "codex-cli 0.164.0"), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
    #expect(result.version == "0.164.0")
    #expect(result.parts.map(\.title) == ["b", "a"])
    #expect(result.parts[0].notes.contains("Configured model"))
}

@Test func cachedOpenCodeFileSkipsFetch() async throws {
    let f = try Fixture(); defer { f.remove() }
    let cache = f.layout.path("cache")
    try f.write("cache/opencode/1.19.5/index.json", #"["codex.txt"]"#)
    try f.write("cache/opencode/1.19.5/codex.txt", "cached")
    let fetcher = CountingFetcher()
    let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: fetcher, cacheRoot: cache)
    #expect(result.parts.map(\.title) == ["codex.txt"])
    #expect(await fetcher.count == 0)
}

@Test func failedListingIsRetryableUnavailable() async throws {
    let f = try Fixture(); defer { f.remove() }
    let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
    #expect(result.version == "1.19.5")
    guard case .unavailable(let reason) = result.parts.first?.status else { Issue.record("expected unavailable"); return }
    #expect(reason.hasPrefix("Could not list prompts:"))
    #expect(!FileManager.default.fileExists(atPath: f.layout.path("cache/opencode/1.19.5/index.json")))
}

@Test func closedHarnessIsUnavailable() async throws {
    let f = try Fixture(); defer { f.remove() }
    let result = await BasePromptReader.read(harness: .claude, layout: f.layout, runner: StubRunner(output: "2.1.312"), fetcher: FailingFetcher(), cacheRoot: "")
    #expect(result.parts.map(\.status) == [.unavailable("Closed source. Use Capture.")])
}

@Test func versionFailureIsReported() async throws {
    let f = try Fixture(); defer { f.remove() }
    let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "", error: "boom", status: 1), fetcher: FailingFetcher(), cacheRoot: "")
    #expect(result.parts.map(\.status) == [.unavailable("Could not read version: boom")])
}
```

Create `Tests/SkillShelfCoreTests/Stubs.swift` with `StubRunner` (fixed `CommandResult`), `FailingFetcher` (throws `URLError(.notConnectedToInternet)`) and `CountingFetcher` (actor counting calls, returns empty data).

- [ ] **Step 2: Run `swift test --filter BasePromptReaderTests`.** Expected: FAIL.
- [ ] **Step 3: Implement.** The OpenCode listing is cached as `index.json` (array of file names ending in `.txt`) beside the files. File contents are fetched lazily by `PromptContent` (Task 10), not here; `read` fetches only the listing. Codex falls back to one `.remote(url: codexFallbackURL, cache: cachePath(..., file: "prompt.md"))` part titled `prompt.md` when the cache is missing or has no `models`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add base prompt reader`.

---

### Task 5: Capture record and parser

**Files:**
- Create: `Sources/SkillShelfCore/CaptureRecord.swift`, `Sources/SkillShelfCore/CaptureParser.swift`
- Test: `Tests/SkillShelfCoreTests/CaptureParserTests.swift`

**Interfaces:**
- Produces:
  - `public struct CapturedRequest: Codable, Sendable, Hashable { public let method: String; public let path: String; public let body: String; public let bodyEncoding: String? }` (`bodyEncoding` set to the `Content-Encoding` value when the body is stored base64).
  - `public struct CaptureRecord: Codable, Sendable { public let harness: String; public let version: String?; public let adapter: String; public let command: [String]; public let date: Date; public let notes: [String]; public let requests: [CapturedRequest]; public let diagnostics: String? }` with `public func save(to directory: String) throws -> String` (creates dirs `0700`, writes `<ISO8601>.json` `0600`, returns path) and `public static func load(_ path: String) throws -> CaptureRecord`.
  - `public enum MainRequest: Sendable, Equatable { case found(Int), bestGuess(Int), unknown }`
  - `public struct CaptureSections: Sendable { public var system: [String]; public var tools: [(name: String, summary: String)]; public var toolsJSON: String?; public var messages: [(role: String, text: String)]; public var raw: String? }`
  - `public enum CaptureParser { public static func mainRequest(_ requests: [CapturedRequest], sentinel: String) -> MainRequest; public static func sections(_ body: String) -> CaptureSections; public static func hasTools(_ body: String) -> Bool }`
  - The sentinel is stored in `notes` as `"sentinel: <value>"` so `mainRequest` can be recomputed on load.

- [ ] **Step 1: Write failing tests**

```swift
@Test func anthropicBodySplitsSystemToolsMessages() {
    let s = CaptureParser.sections(#"{"system":[{"type":"text","text":"You are X"}],"tools":[{"name":"Bash","description":"Run.\nMore"}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#)
    #expect(s.system == ["You are X"])
    #expect(s.tools.map(\.name) == ["Bash"]); #expect(s.tools[0].summary == "Run.")
    #expect(s.messages.map(\.role) == ["user"])
}

@Test func responsesBodySplitsInstructionsInputTools() {
    let s = CaptureParser.sections(#"{"instructions":"Base","input":[{"role":"developer","content":[{"type":"input_text","text":"dev"}]},{"role":"user","content":"hi"}],"tools":[{"type":"function","name":"shell","description":"Run"}]}"#)
    #expect(s.system == ["Base"])
    #expect(s.messages.map(\.role) == ["developer", "user"])
    #expect(s.tools.map(\.name) == ["shell"])
}

@Test func unknownBodyFallsBackToRaw() {
    #expect(CaptureParser.sections(#"{"weird":1}"#).raw?.contains("\"weird\" : 1") == true)
}

@Test func mainRequestPrefersSentinelWithTools() {
    let s = "SKILLSHELF_CAPTURE_X"
    let title = CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"messages":[{"role":"user","content":"\#(s)"}]}"#, bodyEncoding: nil)
    let main = CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"tools":[{"name":"a"}],"messages":[{"role":"user","content":"\#(s)"}]}"#, bodyEncoding: nil)
    #expect(CaptureParser.mainRequest([title, main], sentinel: s) == .found(1))
    #expect(CaptureParser.mainRequest([title], sentinel: s) == .bestGuess(0))
    #expect(CaptureParser.mainRequest([CapturedRequest(method: "POST", path: "/x", body: "{}", bodyEncoding: nil)], sentinel: s) == .unknown)
}

@Test func savedRecordIsPrivate() throws {
    let f = try Fixture(); defer { f.remove() }
    let path = try CaptureRecord(harness: "claude", version: "2.1.312", adapter: "anthropic", command: ["claude", "-p"], date: .now, notes: [], requests: [], diagnostics: nil).save(to: f.layout.path("captures/claude"))
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    let dir = try FileManager.default.attributesOfItem(atPath: f.layout.path("captures/claude"))
    #expect((dir[.posixPermissions] as? Int) == 0o700)
}
```

- [ ] **Step 2: Run `swift test --filter CaptureParserTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** with `JSONSerialization`. Also add the 64 MB total-body limit and the stderr `diagnostics` field to the spec's PromptCapture section in this commit. Anthropic `system` may be a string or blocks; `content` may be a string or blocks (join `text` fields). Responses `input` content may be a string or `input_text`/`output_text` blocks. `toolsJSON` is the pretty-printed `tools` array. Use `.sortedKeys` and `.prettyPrinted` for `raw`. Write the file with `FileManager.createFile(atPath:contents:attributes: [.posixPermissions: 0o600])`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add capture record and parser`.

---

### Task 6: CaptureListener

**Files:**
- Create: `Sources/SkillShelfCore/CaptureListener.swift`, `Sources/SkillShelfCore/HTTPRequestParser.swift`
- Test: `Tests/SkillShelfCoreTests/CaptureListenerTests.swift`, `Tests/SkillShelfCoreTests/Stubs.swift` (helpers)

**Interfaces:**
- Consumes: `CapturedRequest`.
- Produces:
  - `public enum CaptureFormat: Sendable { case anthropic, openAI }` with `var errorBody: String` returning the spec's exact JSON bodies.
  - `struct HTTPRequestParser` (internal): `init(limits: CaptureLimits)`, `mutating func feed(_ data: Data) -> Result?` (nil while incomplete) where `enum Result { case request(method: String, path: String, body: Data, encoding: String?), tooLarge(String), upgrade, malformed }`. Supports `Content-Length` and `Transfer-Encoding: chunked`, input split across any number of `feed` calls.
  - `public struct CaptureLimits: Sendable { public var headerBytes = 65_536; public var bodyBytes = 33_554_432; public var totalBodyBytes = 67_108_864; public var connections = 8; public var requests = 30; public static let standard = CaptureLimits() }`
  - `public final class CaptureListener: Sendable { public init(format: CaptureFormat, limits: CaptureLimits = .standard); public func start() async throws -> UInt16; public var requests: AsyncStream<CapturedRequest> { get }; public func notes() -> [String]; public func stop() async }`. `stop()` returns only after the `NWListener` and every connection reached `.cancelled`. Mutable state lives in a `Mutex` from `Synchronization`.
  - Notes strings: `"Request over the \(name) limit was dropped"` (`name` is `header`, `body`, `total body`, `connection` or `request`), `"Compressed body (\(encoding)), not decoded"`, `"WebSocket upgrade refused"`.
  - Test helper in `Stubs.swift`: `func withListener<T>(_ format: CaptureFormat, limits: CaptureLimits = .standard, _ body: (CaptureListener, UInt16) async throws -> T) async throws -> T` that always awaits `stop()`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func recordsBodyAndAnswersAdapterError() async throws {
    try await withListener(.anthropic) { listener, port in
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"; request.httpBody = Data(#"{"a":1}"#.utf8)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        #expect(String(decoding: data, as: UTF8.self) == CaptureFormat.anthropic.errorBody)
        var iterator = listener.requests.makeAsyncIterator()
        let captured = await iterator.next()
        #expect(captured?.body == #"{"a":1}"#)
        #expect(captured.map { String(describing: $0) }?.contains("secret") == false)
    }
}

@Test func chunkedBodySplitAcrossFeedsIsReassembled() throws {
    var parser = HTTPRequestParser(limits: .standard)
    let raw = Array("POST /r HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
    var result: HTTPRequestParser.Result?
    for byte in raw { result = parser.feed(Data([byte])) ?? result }
    guard case .request(_, _, let body, _) = result else { Issue.record("no request"); return }
    #expect(String(decoding: body, as: UTF8.self) == "abcde")
}

@Test func oversizedHeaderAndBodyAreRejected() {
    var body = HTTPRequestParser(limits: CaptureLimits(bodyBytes: 4))
    guard case .tooLarge("body") = body.feed(Data("POST /r HTTP/1.1\r\nContent-Length: 10\r\n\r\n".utf8)) else { Issue.record("body"); return }
    var header = HTTPRequestParser(limits: CaptureLimits(headerBytes: 16))
    guard case .tooLarge("header") = header.feed(Data("POST /r HTTP/1.1\r\nX-Long: aaaaaaaaaaaa\r\n".utf8)) else { Issue.record("header"); return }
}

@Test func gzipBodyIsStoredEncodedWithNote() async throws {
    try await withListener(.openAI) { listener, port in
        _ = try? await rawPost(port: port, headers: ["Content-Encoding: gzip"], body: Data([0x1f, 0x8b, 0x08]))
        var iterator = listener.requests.makeAsyncIterator()
        #expect(await iterator.next()?.bodyEncoding == "gzip")
        #expect(listener.notes().contains("Compressed body (gzip), not decoded"))
    }
}

@Test func upgradeIsRefused() async throws {
    try await withListener(.openAI) { listener, port in
        let status = try await rawPost(port: port, headers: ["Connection: Upgrade", "Upgrade: websocket"], body: Data())
        #expect(status == 400)
        #expect(listener.notes().contains("WebSocket upgrade refused"))
    }
}

@Test func requestAndTotalLimitsDropExtras() async throws {
    try await withListener(.openAI, limits: CaptureLimits(totalBodyBytes: 10, requests: 2)) { listener, port in
        for _ in 0..<3 { _ = try? await rawPost(port: port, headers: [], body: Data("123456".utf8)) }
        #expect(listener.notes().contains("Request over the total body limit was dropped"))
        #expect(listener.notes().contains("Request over the request limit was dropped"))
    }
}

@Test func connectionLimitClosesExtraConnections() async throws {
    try await withListener(.openAI, limits: CaptureLimits(connections: 1)) { listener, port in
        let first = try openIdleConnection(port: port); defer { close(first) }
        _ = try? await rawPost(port: port, headers: [], body: Data("x".utf8))
        #expect(listener.notes().contains("Request over the connection limit was dropped"))
    }
}

@Test func listenerIsLoopbackOnly() async throws {
    try await withListener(.openAI) { _, port in
        let addresses = LocalAddresses.nonLoopbackIPv4()
        try #require(!addresses.isEmpty, "needs a non-loopback interface")
        #expect(addresses.allSatisfy { !TCPProbe.connects(host: $0, port: port) })
    }
}
```

`Stubs.swift` helpers: `rawPost(port:headers:body:) async throws -> Int` (raw socket HTTP/1.1, returns status), `openIdleConnection(port:) throws -> Int32`, `LocalAddresses.nonLoopbackIPv4()` (`getifaddrs`), `TCPProbe.connects(host:port:) -> Bool` (non-blocking `connect`, 1 s timeout).

- [ ] **Step 2: Run `swift test --filter CaptureListenerTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** on `NWListener` with `parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)` and `parameters.acceptLocalOnly = true`. Each connection feeds an `HTTPRequestParser`; header bytes are discarded after framing. Every response is `HTTP/1.1 400 Bad Request`, `Content-Type: application/json`, `Connection: close`, exact `errorBody`. Over-limit requests get the same response, are not recorded, and add the note once per limit name.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add loopback capture listener`.

---

### Task 7: Sandbox and CaptureProcess

**Files:**
- Create: `Sources/SkillShelfCore/CaptureProcess.swift`, `Sources/SkillShelfCore/CaptureSandbox.swift`, `Sources/SandboxProbe/main.swift`
- Modify: `Package.swift` (add `.executableTarget(name: "SandboxProbe")`, and make the test target depend on it so `swift test` builds it)
- Test: `Tests/SkillShelfCoreTests/CaptureProcessTests.swift`

**Interfaces:**
- Produces:
  - `public enum CaptureError: Error, Equatable, LocalizedError { case sandboxUnavailable, busy, notInstalled, noRequest(version: String?) }`, texts copied from the spec's Errors table.
  - `public enum CaptureSandbox { public static let executable = "/usr/bin/sandbox-exec"; public static func profile(port: UInt16, unixSockets: [String] = []) -> String; public static func wrap(_ argv: [String], port: UInt16, unixSockets: [String]) throws -> [String]; public static func verify(port: UInt16, unixSockets: [String]) async throws }`. `profile` returns the spec's four-line profile with the port, plus one `(allow network-outbound (remote unix-socket (path-literal "<path>")))` line per socket. `wrap` throws `.sandboxUnavailable` when the executable is missing. `verify` runs `sandbox-exec -p <profile> /usr/bin/true` and throws `.sandboxUnavailable` on a non-zero exit; `PromptCapture` calls it before launching the harness.
  - `public protocol CaptureProcessHandle: Sendable { var pid: pid_t { get }; func terminate() async; func exitStatus() async -> Int32; func diagnostics() async -> (stdout: String, stderr: String) }`
  - `public protocol CaptureProcessLaunching: Sendable { func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle }`
  - `public struct SpawnLauncher: CaptureProcessLaunching` using `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgroup 0), stdin `/dev/null`, stdout and stderr to pipes drained concurrently into ring buffers keeping the last 262_144 bytes each. `terminate()` sends `SIGTERM` to `-pid`, waits up to 3 s for the group to empty (`kill(-pid, 0)` fails with `ESRCH`), then `SIGKILL` to `-pid`, then reaps.
  - `public enum CaptureEnvironment { public static func sanitized(_ base: [String: String]) -> [String: String] }` removing the spec's credential and proxy variables: prefixes `ANTHROPIC_`, `OPENAI_`, `GOOGLE_`, `XAI_`; exact `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`; case-insensitive.
  - `SandboxProbe` executable: `SandboxProbe <url>` does a `URLSession` GET and prints the HTTP status, or `error <NSURLError code> <underlying POSIX code>` on failure.

- [ ] **Step 1: Write failing tests.** Each denial is paired with an unsandboxed control that succeeds, so a test cannot pass for the wrong reason.

```swift
@Test func sanitizedEnvironmentDropsCredentialsAndProxies() {
    let env = CaptureEnvironment.sanitized(["PATH": "/bin", "ANTHROPIC_API_KEY": "k", "https_proxy": "x", "OPENAI_BASE_URL": "u", "CLAUDE_CODE_OAUTH_TOKEN": "t", "HOME": "/h"])
    #expect(env == ["PATH": "/bin", "HOME": "/h"])
}

@Test func sandboxAllowsOnlyCapturePortForCurlAndDescendants() async throws {
    try await withListener(.openAI) { _, port in
        try await withListener(.openAI) { _, other in
            let curl = { (p: UInt16) in "curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:\(p)/x 2>&1" }
            #expect(try runShell(curl(other)) == "400")
            #expect(try runShell(curl(port), sandboxPort: port) == "400")
            #expect(try runShell(curl(other), sandboxPort: port).contains("Operation not permitted"))
            #expect(try runShell("/bin/sh -c \"\(curl(other))\"", sandboxPort: port).contains("Operation not permitted"))
        }
    }
}

@Test func sandboxBlocksNonLoopbackAndUnixSockets() async throws {
    let address = try #require(LocalAddresses.nonLoopbackIPv4().first, "needs a non-loopback interface")
    let tcp = try TestTCPServer(bind: "0.0.0.0"); defer { tcp.close() }
    #expect(try runShell("nc -z -G 1 \(address) \(tcp.port); echo $?") == "0")
    #expect(try runShell("nc -z -G 1 \(address) \(tcp.port) 2>&1; echo $?", sandboxPort: 9).contains("Operation not permitted"))
    let unix = try TestUnixServer(); defer { unix.close() }
    #expect(try runShell("nc -U -z \(unix.path); echo $?") == "0")
    #expect(try runShell("nc -U -z \(unix.path) 2>&1; echo $?", sandboxPort: 9).contains("Operation not permitted"))
}

@Test func sandboxCoversURLSessionClients() async throws {
    try await withListener(.openAI) { _, port in
        try await withListener(.openAI) { _, other in
            #expect(try runProbe("http://127.0.0.1:\(port)/x", sandboxPort: port) == "400")
            #expect(try runProbe("http://127.0.0.1:\(other)/x") == "400")
            #expect(try runProbe("http://127.0.0.1:\(other)/x", sandboxPort: port).hasSuffix(" 1"))
        }
    }
}

@Test func invalidProfileFailsVerify() async {
    await #expect(throws: CaptureError.sandboxUnavailable) { try await CaptureSandbox.verify(port: 1, unixSockets: ["\")(allow"]) }
}

@Test func terminateKillsWholeProcessGroup() async throws {
    let dir = try TempDir(); defer { dir.remove() }
    let handle = try SpawnLauncher().launch(argv: ["/bin/sh", "-c", "sleep 60 & echo $! > \(dir.path)/child; sleep 60"], environment: [:], cwd: dir.path)
    try await waitForFile(dir.path + "/child", timeout: .seconds(5))
    await handle.terminate()
    #expect(kill(-handle.pid, 0) == -1 && errno == ESRCH)
}

@Test func diagnosticsKeepTailOfStderr() async throws {
    let handle = try SpawnLauncher().launch(argv: ["/bin/sh", "-c", "echo 'MCP server foo failed to connect' >&2"], environment: [:], cwd: NSTemporaryDirectory())
    _ = await handle.exitStatus()
    #expect(await handle.diagnostics().stderr.contains("MCP server foo failed"))
}
```

`Stubs.swift` helpers: `runShell(_ command: String, sandboxPort: UInt16? = nil) throws -> String` (runs `/bin/sh -c`, wrapped by `CaptureSandbox.wrap` when a port is given; trimmed stdout), `runProbe(_ url: String, sandboxPort: UInt16? = nil) throws -> String` (runs the built `SandboxProbe` from `Bundle.module`'s sibling build dir), `TestTCPServer`, `TestUnixServer`, `TempDir`, `waitForFile(_:timeout:)`. POSIX `EPERM` is 1, hence `hasSuffix(" 1")`.

- [ ] **Step 2: Run `swift test --filter CaptureProcessTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** per the interfaces.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add capture sandbox and process launcher`.

---

### Task 8: PromptCapture, adapters and login runner hooks

**Files:**
- Create: `Sources/SkillShelfCore/PromptCapture.swift`, `Sources/SkillShelfCore/CaptureAdapters.swift`
- Modify: `Sources/SkillShelfCore/CommandRunner.swift` (`LoginShellRunner` gains two methods; `CommandRunning` unchanged)
- Test: `Tests/SkillShelfCoreTests/PromptCaptureTests.swift`

**Interfaces:**
- Consumes: Tasks 5–7.
- Produces:
  - `LoginShellRunner`: `public func resolve(_ tool: String) async -> String?` (existing PATH lookup, extracted) and `public func loginEnvironment() async -> [String: String]` (process environment with the login `PATH`).
  - `public struct CaptureAdapter: Sendable { public let harness: HarnessID; public let tool: String; public let format: CaptureFormat; public let unixSockets: [String]; public let launch: @Sendable (_ baseURL: String, _ sentinel: String) -> (arguments: [String], environment: [String: String]) }`
  - `public enum CaptureAdapters { public static let placeholder = "skillshelf-placeholder"; public static func adapter(for harness: HarnessID) -> CaptureAdapter?; public static func unavailableReason(for harness: HarnessID) -> String? }`. Claude, Codex, OpenCode per the spec table. Grok and Muse return `nil` with `"Requires real login"` until Task 9 enables them. Cursor `"Prompt is assembled on Cursor's servers"`. Antigravity `"No verified local redirect"`. `baseURL` is `http://127.0.0.1:<port>`.
  - `public enum DiagnosticNotes { public static func mcpFailures(_ text: String) -> [String] }`: one note `"MCP server <name> failed"` per stdout or stderr line matching `(?i)mcp.*?\b(server\s+)?["'“]?([\w.-]+)["'”]?.*\b(fail|error|could not connect|unable)`; unmatched MCP lines are ignored.
  - `public actor PromptCapture { public init(launcher: any CaptureProcessLaunching = SpawnLauncher(), resolveTool: @escaping @Sendable (String) async -> String?, loginEnvironment: @escaping @Sendable () async -> [String: String], capturesRoot: String, tempRoot: String = NSTemporaryDirectory(), timeout: Duration = .seconds(60)); public func run(_ adapter: CaptureAdapter, version: String?) async throws -> String }` returning the saved path. Default `capturesRoot`: `~/Library/Application Support/SkillShelf/captures`.
  - `CaptureRecord.diagnostics` (Task 5) holds the last 4 KB of stderr.

- [ ] **Step 1: Write failing tests.** Every test passes its own `TempDir` as `tempRoot` and `capturesRoot`, and a `RecordingLauncher` (wraps `SpawnLauncher`, exposes launched pids) for process assertions.

```swift
@Test func claudeAdapterBuildsPlaceholderLaunch() throws {
    let adapter = try #require(CaptureAdapters.adapter(for: .claude))
    let launch = adapter.launch("http://127.0.0.1:9", "S")
    #expect(launch.arguments == ["-p", "S"])
    #expect(launch.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9")
    #expect(launch.environment["ANTHROPIC_API_KEY"] == CaptureAdapters.placeholder)
}

@Test func mcpFailureLinesBecomeNotes() {
    #expect(DiagnosticNotes.mcpFailures("MCP server \"github\" failed to connect\nok\n[mcp] linear: error: ECONNREFUSED") == ["MCP server github failed", "MCP server linear failed"])
}

@Test func captureStopsOnSentinelRequestAndCleansUp() async throws {
    let dir = try TempDir(); defer { dir.remove() }
    let script = try dir.script("fake.sh", """
    #!/bin/sh
    echo 'MCP server "remote" failed to connect' >&2
    curl -s -X POST "$BASE/v1/messages" -d "{\\"tools\\":[{\\"name\\":\\"a\\"}],\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"$1\\"}]}"
    sleep 60
    """)
    let adapter = CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: []) { base, s in ([s], ["BASE": base]) }
    let launcher = RecordingLauncher()
    let capture = PromptCapture(launcher: launcher, resolveTool: { _ in script }, loginEnvironment: { ["PATH": "/usr/bin:/bin"] }, capturesRoot: dir.path + "/captures", tempRoot: dir.path + "/tmp")
    let start = ContinuousClock.now
    let path = try await capture.run(adapter, version: "1.0")
    #expect(ContinuousClock.now - start < .seconds(10))
    let record = try CaptureRecord.load(path)
    #expect(record.requests.count == 1)
    #expect(record.notes.contains("MCP server remote failed"))
    #expect(!(try String(contentsOfFile: path, encoding: .utf8)).localizedCaseInsensitiveContains("user-agent"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path + "/tmp").isEmpty)
    #expect(launcher.pids.allSatisfy { kill(-$0, 0) == -1 })
}

@Test func secondCaptureWhileBusyThrows() async throws { /* fake.sh: `sleep 60`; start run in a Task; waitForFile on a marker the script writes first; expect `CaptureError.busy` from a second run; cancel the first Task and await it */ }

@Test func noRequestTimesOutWithMessage() async throws { /* fake.sh: `sleep 60`, timeout .seconds(2); expect CaptureError.noRequest(version: "1.0"); tmp dir empty; launcher pids gone */ }

@Test func cancellationCleansUp() async throws { /* fake.sh writes marker then `sleep 60`; start run in a Task, waitForFile(marker), cancel, await; expect CancellationError; tmp dir empty; pids gone */ }

@Test func missingToolThrowsNotInstalled() async throws { /* resolveTool returns nil; expect CaptureError.notInstalled; launcher never called */ }

@Test func loginRunnerResolvesSh() async {
    #expect(await LoginShellRunner().resolve("sh") == "/bin/sh")
}
```

Write the four commented tests fully in the same style as `captureStopsOnSentinelRequestAndCleansUp`; synchronize on marker files, never on fixed sleeps.

- [ ] **Step 2: Run `swift test --filter PromptCaptureTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** the spec's Run steps 1–9 in order. Busy flag set before the first `await`. `CaptureSandbox.verify` runs before the harness launches. Temp dir `<tempRoot>/skillshelf-capture-<UUID>`. Environment: `CaptureEnvironment.sanitized(loginEnvironment())` merged with the adapter's environment. argv: `try CaptureSandbox.wrap([tool path] + arguments, port:, unixSockets:)`. Watch `listener.requests`; stop on the first request where `CaptureParser.hasTools` and the body contains the sentinel, on process exit, or on timeout. Cleanup is awaited on every path and on cancellation (`withTaskCancellationHandler`): `terminate`, `listener.stop`, remove temp dir. Throw `CaptureError.noRequest` when zero requests were recorded. Notes: `"sentinel: <value>"`, `"Placeholder auth: account-specific text may differ"`, listener notes, `DiagnosticNotes.mcpFailures` over both diagnostics streams. The saved `command` replaces the placeholder value with `<placeholder>`.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add prompt capture orchestration`.

---

### Task 9: Verify adapters on this Mac

Manual task; runs real harnesses only against the local listener inside the sandbox, as the spec allows.

**Files:**
- Modify: `Sources/SkillShelfCore/CaptureAdapters.swift`, the spec's adapter table if a Unix socket or flag changes
- Test: `Tests/SkillShelfCoreTests/LiveCaptureTests.swift`

- [ ] **Step 1:** Add `@Test(.enabled(if: ProcessInfo.processInfo.environment["SKILLSHELF_LIVE_CAPTURE"] == "1")) func liveCapture()` running `PromptCapture` with `LoginShellRunner.resolve` and `loginEnvironment` for Claude, Codex and OpenCode, printing per harness: request count, main-request status, tool count, notes and the saved `diagnostics`.
- [ ] **Step 2:** Run `SKILLSHELF_LIVE_CAPTURE=1 swift test --filter liveCapture`. Expected: Claude, Codex and OpenCode each report `found` with tools > 0 within 60 s. On a failure, read `diagnostics`, fix flags or add the exact Unix socket path the harness needs, and record it in the spec's adapter table. Check that MCP failures the harness prints appear as notes; adjust the `DiagnosticNotes` pattern and its test to the real wording.
- [ ] **Step 3:** Try Grok (`GROK_CLI_CHAT_PROXY_BASE_URL` plus the placeholder variable its `~/.grok/docs/user-guide/11-custom-models.md` names) and Muse (`--base-url` plus the key variable `muse exec --help` names). Enable each adapter only if it reaches `found`; otherwise keep the `nil` adapter and its reason.
- [ ] **Step 4: Run `swift test`.** Expected: all pass (live test skipped).
- [ ] **Step 5: Commit** `Verify capture adapters` with the spec table update.

---

### Task 10: PromptContent

**Files:**
- Create: `Sources/SkillShelfCore/PromptContent.swift`
- Test: `Tests/SkillShelfCoreTests/PromptContentTests.swift`

**Interfaces:**
- Consumes: `PromptPart`, `PromptFetching`, `TOMLKeys`, `JSONC`, `CaptureRecord`, `CaptureParser`, `Frontmatter`.
- Produces:
  - `public enum PromptText: Sendable, Equatable { case markdown(String), code(String, language: String), failed(String) }`
  - `public enum PromptContent { @concurrent public static func load(_ part: PromptPart, fetcher: any PromptFetching) async -> PromptText }`

Rendering rules:
- `.file`, no key: `.md` gives `.markdown` of `Frontmatter.body(text)`; other extensions give `.code(text, language: <ext>)`.
- `.file` with a key into `.toml` or `.json(c)`: `.code(value, language: "text")`, multi-line values included (spec: config values as code blocks).
- `.file` with key `models.<slug>` in `models_cache.json`: `.markdown` with `## <key path>` and the text of every string leaf of `model_messages`, depth-first in file order.
- `.remote(url, cache: path?)` with a cache path: cached file if present; else fetch, write the cache, return `.markdown`. Fetch failure with a cached copy returns the copy; without one, `.failed(error.localizedDescription)`.
- `.remote(url, cache: nil)`: fetch every time, never written to disk.
- `.capture(path)`: header lines (version, adapter, notes), then `## System`, `## Tools (<n>)` with `- **name**: summary` and the JSON in a fenced block, `## Messages` with `### <role>`, `## Helper calls` listing method and path of the others. `.unknown` lists every request under `## Requests`. `diagnostics` goes in a final `## Harness output` fenced block.

- [ ] **Step 1: Write failing tests**

```swift
@Test func tomlKeyPartIsCode() async throws { /* developer_instructions = """\nA\nB""" -> .code("A\nB", language: "text") */ }
@Test func codexModelRendersStringLeaves() async throws { /* models_cache with model_messages.approvals.never = "N" -> markdown contains "## approvals.never\n\nN" */ }
@Test func versionedRemoteUsesCacheWhenFetchFails() async throws { /* cache file present + FailingFetcher -> .markdown(cached) */ }
@Test func versionedRemoteFailureWithoutCacheIsFailed() async throws { /* FailingFetcher, no cache -> .failed */ }
@Test func instructionRemoteIsNeverCached() async throws { /* .remote(url, cache: nil) with CountingFetcher returning "x" loaded twice -> 2 fetches, no files written under the temp home */ }
@Test func captureRendersSectionsHelperCallsAndOutput() async throws { /* record with one title call, one main call, diagnostics "boom" -> "## Tools (1)", "## Helper calls", "## Harness output" */ }
@Test func largeFileLoadsWithoutTruncation() async throws { /* 5 MB AGENTS.md -> markdown count == 5 MB */ }
```

Write each body fully, following the Task 4 and Task 5 fixtures.

- [ ] **Step 2: Run `swift test --filter PromptContentTests`.** Expected: FAIL.
- [ ] **Step 3: Implement** per the rendering rules.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Add prompt content loader`.

---

### Task 11: Prompt state and loading

**Files:**
- Create: `Sources/SkillShelf/PromptState.swift`
- Modify: `Sources/SkillShelfCore/Models.swift` (`Snapshot.prompts`), `Sources/SkillShelfCore/SkillScanner.swift`, `Sources/SkillShelf/AppModel.swift`
- Test: `Tests/SkillShelfCoreTests/SkillScannerTests.swift`, `Tests/SkillShelfCoreTests/CaptureParserTests.swift`

**Interfaces:**
- Consumes: Tasks 2–10.
- Produces:
  - `Snapshot.prompts: [HarnessID: [PromptPart]]` (init default `[:]`), filled in `SkillScanner.snapshot(layout:inputs:generation:)` for each installed harness with one shared `InstructionFiles` per scan.
  - `public enum CaptureIndex { @concurrent public static func list(harness: HarnessID, capturesRoot: String) async -> [PromptPart] }`: newest first, title `<date> · <main request status>`, reading only file names and each record's small header fields.
  - `SidebarItem.prompts(HarnessID)`.
  - `@MainActor @Observable final class PromptState` held as `AppModel.prompts`:
    - `instructions: [HarnessID: [PromptPart]]`, set from the snapshot under the existing generation guard.
    - `base: [HarnessID: BaseState]` with `enum BaseState { case loading, loaded(BasePrompts) }`. `loadBase(_ harness:, force: Bool = false) async` re-reads the version on every call and reloads when the version changed, `force` is true, or nothing is loaded.
    - `captures: [HarnessID: [PromptPart]]`, `loadCaptures(_:) async` through `CaptureIndex.list`.
    - `selection: PromptPart.ID?`, cleared after a refresh only when `part(id:)` returns nil.
    - `contentGeneration: Int`, incremented on every refresh and after each capture, so open text reloads.
    - `capturing: HarnessID?`, `captureError: [HarnessID: String]`, `capture(_:) async`.
    - `parts(for:) -> [PromptPart]`, `part(id:) -> PromptPart?`.
  - Scans stay coalesced by the existing generation check; `refresh` is not re-entered while a scan runs (`isScanning` guard returns early and sets a `rescanRequested` flag that triggers one more scan at the end).

- [ ] **Step 1: Write failing tests**

```swift
@Test func snapshotCarriesInstructionParts() throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    try fixture.write(".codex/AGENTS.md", "x")
    #expect(fixture.snapshot().prompts[.codex]?.contains { $0.title == "~/.codex/AGENTS.md" } == true)
}

@Test func captureIndexListsNewestFirst() async throws { /* two saved records 1 s apart -> list returns newer first, titles contain the main request status */ }
```

- [ ] **Step 2: Run `swift test`.** Expected: new tests FAIL.
- [ ] **Step 3: Implement** the interfaces. All file and network work runs in `@concurrent` Core functions; `PromptState` only awaits them and assigns.
- [ ] **Step 4: Run `swift test`.** Expected: all pass.
- [ ] **Step 5: Commit** `Load prompt state alongside the skill scan`.

---

### Task 12: Prompts UI

**Files:**
- Create: `Sources/SkillShelf/PromptPartList.swift`, `Sources/SkillShelf/PromptTextView.swift`
- Modify: `Sources/SkillShelf/ContentView.swift` (sidebar section, content and detail switch, toolbar)

**Interfaces:**
- Consumes: `PromptState` (Task 11), `PromptContent.load` (Task 10), `MarkdownTheme.shelf`.
- Produces: views only.

- [ ] **Step 1:** Sidebar section "System prompts" below "Harnesses", one row per installed harness with `HarnessIcon` and a badge of present parts. Selecting a row calls `loadBase` and `loadCaptures`.
- [ ] **Step 2:** `PromptPartList`: sections "Instructions", "Agent definitions" (only when non-empty), "Base prompt @ <version>" (with a Retry button when any base part is `.unavailable` with a reason starting `Could not`, calling `loadBase(force: true)`), "Capture" (header button "Capture now", disabled while `capturing != nil` or when `CaptureAdapters.adapter(for:)` is nil, with the unavailable reason as help; `ProgressView` while capturing; error text from `captureError`). Status icons: `checkmark.circle` present, `circle.dashed` in `.secondary` missing, `minus.circle` unavailable with `.help(reason)`. Notes in `.caption` `.secondary`. Search filters titles.
- [ ] **Step 3:** `PromptTextView`: `.task(id: "\(part.id)#\(prompts.contentGeneration)")` awaits `PromptContent.load`, then builds the display off the main actor in a `@concurrent` helper returning an `@unchecked Sendable` wrapper around `MarkdownContent` (same pattern as `SkillFileView.load`; `.code` becomes a fenced block, `.failed` an error label with Retry that bumps a local reload counter). Header: title, source line (`layout.display(path)` or URL), version, notes. Toolbar when a prompt part is selected: Reveal in Finder (file and capture sources), Open, Copy text (copies the loaded text).
- [ ] **Step 4:** `swift build && ./scripts/package-app.sh && open dist/SkillShelf.app`. Check by hand: every installed harness appears under "System prompts"; Codex lists `~/.codex/AGENTS.md` and `gpt-6.1-sol` first under "Base prompt @ 0.164.0"; OpenCode shows two parts noted "loaded twice"; ⌘R keeps the selected part and reloads its text after editing the file; a Claude capture finishes and appears at the top of the list; selecting a 5 MB part leaves the list responsive.
- [ ] **Step 5: Commit** `Add system prompts view`.

---

### Task 13: Docs and screenshots

**Files:**
- Modify: `docs/plan.md`, `README.md`

- [ ] **Step 1:** Add a "System prompts" section to `docs/plan.md` summarizing the spec's three tables and capture rules. Add this sentence to the README after the first paragraph: "It also shows each harness's system prompt: instruction files, the vendor base prompt where it is public, and a sandboxed capture of the request it sends."
- [ ] **Step 2:** Take before and after screenshots of the app window (before: build from the commit preceding Task 12; after: Codex selected under "System prompts") and a short screen recording of a Claude capture, for the user.
- [ ] **Step 3: Run `swift test`.** Expected: all pass.
- [ ] **Step 4: Commit** `Document system prompts view`.
