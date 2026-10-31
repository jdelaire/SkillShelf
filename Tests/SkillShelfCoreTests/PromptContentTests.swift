import Foundation
import Testing
@testable import SkillShelfCore

struct PromptContentTests {
    @Test func tomlGlobalContentExcludesQuotedProfileValues() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        try f.write(".codex/config.toml", #"""
        instructions = "global"
        [profiles."review"]
        instructions = "profile-only"
        developer_instructions = "profile-only"
        """#)
        let path = f.layout.path(".codex/config.toml")
        #expect(await PromptContent.load(part(.file(path: path, key: "instructions")), fetcher: FailingFetcher()) == .code("global", language: "text"))
        let missing = await PromptContent.load(part(.file(path: path, key: "developer_instructions")), fetcher: FailingFetcher())
        guard case .failed = missing else { Issue.record("Profile-only key must not load as global content"); return }
    }

    @Test func tomlKeyPartIsCode() async throws {
        let f = try Fixture(); defer { f.remove() }
        let text = "developer_instructions = \"\"\"\nA\nB\"\"\"\ninstructions = \"other\""
        try f.write(".codex/config.toml", text)
        let result = await PromptContent.load(part(.file(path: f.layout.path(".codex/config.toml"), key: "developer_instructions")), fetcher: FailingFetcher())
        #expect(result == .code("A\nB", language: "text"))
        #expect(try String(contentsOfFile: f.layout.path(".codex/config.toml"), encoding: .utf8) == text)
    }

    @Test(arguments: ["json", "jsonc"])
    func jsonKeyPartIsCode(_ suffix: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let text = suffix == "json"
            ? #"{"run":{"system_prompt":"A\nB","developer_prompt":"other"}}"#
            : #"{/* settings */"run":{"system_prompt":"A\nB","developer_prompt":"other",},}"#
        let path = ".config/muse/settings." + suffix
        try f.write(path, text)
        let result = await PromptContent.load(part(.file(path: f.layout.path(path), key: "run.system_prompt")), fetcher: FailingFetcher())
        #expect(result == .code("A\nB", language: "text"))
    }

    @Test func openCodeUnresolvedEnvironmentValueRemainsLiteral() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"review.deep":{"prompt":{env:REVIEW_PROMPT}},"other":{"prompt":{file:other.md}}}}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        let prompt = try #require(parts.first { $0.source == .file(path: f.layout.path(".config/opencode/opencode.jsonc"), key: "agent.review.deep.prompt") })
        #expect(await PromptContent.load(prompt, fetcher: FailingFetcher()) == .code("{env:REVIEW_PROMPT}", language: "text"))
    }

    @Test func openCodeFileSubstitutionLoadsReferencedBody() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"review":{"prompt":"{file:prompts/review.md}"}}}"#)
        try f.write(".config/opencode/prompts/review.md", "---\nname: review\n---\nReview carefully.")
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        let prompt = try #require(parts.first { $0.source == .file(path: f.layout.path(".config/opencode/prompts/review.md"), key: nil) })
        #expect(await PromptContent.load(prompt, fetcher: FailingFetcher()) == .markdown("Review carefully."))
    }

    @Test func markdownStripsFrontmatter() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("AGENTS.md", "---\nname: instructions\n---\n# Rules\n\nKeep this.")
        #expect(await PromptContent.load(part(.file(path: f.layout.path("AGENTS.md"), key: nil)), fetcher: FailingFetcher()) == .markdown("# Rules\n\nKeep this."))
    }

    @Test func nonMarkdownFilePreservesTextAndExtension() async throws {
        let f = try Fixture(); defer { f.remove() }
        let text = "---\nname: keep\n---\nText\n"
        try f.write("prompt.txt", text)
        #expect(await PromptContent.load(part(.file(path: f.layout.path("prompt.txt"), key: nil)), fetcher: FailingFetcher()) == .code(text, language: "txt"))
    }

    @Test func codexModelRendersStringLeaves() async throws {
        let f = try Fixture(); defer { f.remove() }
        let cache = #"{"models":[{"slug":"other","model_messages":{"hidden":"NO"}},{"slug":"gpt-6.1","model_messages":{"z_last_alphabetically":"First","approvals":{"never":"N","on_request":"Ask"},"variants":[{"text":"V"},"W"],"a_first_alphabetically":"Last","count":2,"enabled":true,"missing":null}}]}"#
        try f.write(".codex/models_cache.json", cache)
        let result = await PromptContent.load(part(.file(path: f.layout.path(".codex/models_cache.json"), key: "models.gpt-6.1")), fetcher: FailingFetcher())
        #expect(result == .markdown("## z_last_alphabetically\n\nFirst\n\n## approvals.never\n\nN\n\n## approvals.on_request\n\nAsk\n\n## variants.0.text\n\nV\n\n## variants.1\n\nW\n\n## a_first_alphabetically\n\nLast"))
        #expect(try String(contentsOfFile: f.layout.path(".codex/models_cache.json"), encoding: .utf8) == cache)
    }

    @Test func codexModelDecodesEscapedKeysAndValues() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"x","model_messages":{"instruct\u0069ons":"A\n\"B\" ไทย 😀","nested":{"end":"Done"}}}]}"#)
        #expect(await PromptContent.load(part(.file(path: f.layout.path(".codex/models_cache.json"), key: "models.x")), fetcher: FailingFetcher()) == .markdown("## instructions\n\nA\n\"B\" ไทย 😀\n\n## nested.end\n\nDone"))
    }

    @Test func versionedRemoteUsesCacheWhenFetchFails() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = "Library/Caches/SkillShelf/prompts/codex/0.164.0/prompt.md"
        try f.write(path, "cached")
        let prompt = part(.remote(url: URL(string: "https://example.invalid/prompt.md")!, cache: f.layout.path(path)))
        #expect(await PromptContent.load(prompt, fetcher: FailingFetcher()) == .markdown("cached"))
    }

    @Test func cachedRemoteNeverFetchesOrOverwrites() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = "Library/Caches/SkillShelf/prompts/opencode/1.19.5/codex.txt"
        try f.write(path, "cached")
        let fetcher = CountingFetcher("replacement")
        let result = await PromptContent.load(part(.remote(url: URL(string: "https://example.invalid/codex.txt")!, cache: f.layout.path(path))), fetcher: fetcher)
        #expect(result == .markdown("cached"))
        #expect(await fetcher.count == 0)
        #expect(try String(contentsOfFile: f.layout.path(path), encoding: .utf8) == "cached")
    }

    @Test func versionedRemoteWritesCacheAndReusesIt() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.layout.path("Library/Caches/SkillShelf/prompts/opencode/1.19.5/codex.txt")
        let url = URL(string: "https://example.invalid/codex.txt")!
        let prompt = part(.remote(url: url, cache: path))
        let fetcher = StubFetcher("# Base\n\nContent")
        #expect(await PromptContent.load(prompt, fetcher: fetcher) == .markdown("# Base\n\nContent"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "# Base\n\nContent")
        #expect(await PromptContent.load(prompt, fetcher: fetcher) == .markdown("# Base\n\nContent"))
        #expect(await fetcher.urls == [url])
    }

    @Test func versionedRemoteFailureWithoutCacheIsFailed() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.layout.path("Library/Caches/SkillShelf/prompts/codex/0.164.0/prompt.md")
        let result = await PromptContent.load(part(.remote(url: URL(string: "https://example.invalid/prompt.md")!, cache: path)), fetcher: FailingFetcher())
        #expect(result == .failed(URLError(.notConnectedToInternet).localizedDescription))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func unreadableCacheDoesNotFetch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.layout.path("Library/Caches/SkillShelf/prompts/codex/0.164.0/prompt.md")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let fetcher = CountingFetcher("replacement")
        let result = await PromptContent.load(part(.remote(url: URL(string: "https://example.invalid/prompt.md")!, cache: path)), fetcher: fetcher)
        guard case .failed(let error) = result else { Issue.record("Expected cache read failure"); return }
        #expect(!error.isEmpty)
        #expect(await fetcher.count == 0)
    }

    @Test func remoteCacheWriteFailureIsReported() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("Library/Caches/SkillShelf/prompts", "blocker")
        let path = f.layout.path("Library/Caches/SkillShelf/prompts/codex/0.164.0/prompt.md")
        let result = await PromptContent.load(part(.remote(url: URL(string: "https://example.invalid/prompt.md")!, cache: path)), fetcher: CountingFetcher("Base"))
        guard case .failed(let error) = result else { Issue.record("Expected cache write failure"); return }
        #expect(!error.isEmpty)
        #expect(try String(contentsOfFile: f.layout.path("Library/Caches/SkillShelf/prompts"), encoding: .utf8) == "blocker")
    }

    @Test func fetchFailureUsesCacheCreatedDuringFetch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.layout.path("Library/Caches/SkillShelf/prompts/codex/0.164.0/prompt.md")
        let fetcher = CacheWritingFailingFetcher(path: path)
        #expect(await PromptContent.load(part(.remote(url: URL(string: "https://example.invalid/prompt.md")!, cache: path)), fetcher: fetcher) == .markdown("arrived"))
    }

    @Test func instructionRemoteIsNeverCached() async throws {
        let f = try Fixture(installed: []); defer { f.remove() }
        let url = URL(string: "https://example.invalid/\((f.home as NSString).lastPathComponent)/instructions.md")!
        let prompt = part(.remote(url: url, cache: nil))
        let fetcher = CountingFetcher("x")
        #expect(await PromptContent.load(prompt, fetcher: fetcher) == .markdown("x"))
        #expect(await PromptContent.load(prompt, fetcher: fetcher) == .markdown("x"))
        #expect(await fetcher.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.home).isEmpty)
    }

    @Test func captureRendersSectionsHelperCallsAndOutput() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "claude", version: "2.1.312", adapter: "anthropic", command: ["claude", "-p"], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X", "MCP failed: remote"],
            requests: [
                CapturedRequest(method: "POST", path: "/title", body: #"{"messages":[{"role":"user","content":"SKILLSHELF_CAPTURE_X"}]}"#, bodyEncoding: nil),
                CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"system":"Base","tools":[{"name":"Bash","description":"Run.\nMore","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"SKILLSHELF_CAPTURE_X"},{"role":"assistant","content":"Ready"}]}"#, bodyEncoding: nil),
                CapturedRequest(method: "GET", path: "/status", body: "{}", bodyEncoding: nil),
            ], diagnostics: "boom"
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("Version: 2.1.312"))
        #expect(text.contains("Adapter: anthropic"))
        #expect(text.contains("MCP failed: remote"))
        #expect(text.contains("## System\n\n```text\nBase\n```"))
        let rendered = try AttributedString(markdown: text)
        #expect(String(rendered.characters).contains("Bash: Run."))
        let toolsJSON = try #require(text.components(separatedBy: "```json\n").dropFirst().first?.components(separatedBy: "\n```").first)
        let tools = try #require(JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as? [[String: Any]])
        #expect(tools.first?["description"] as? String == "Run.\nMore")
        #expect((tools.first?["input_schema"] as? [String: String])?["type"] == "object")
        #expect(text.contains("## Messages\n\n### user\n\n```text\nSKILLSHELF_CAPTURE_X\n```\n\n### assistant\n\n```text\nReady\n```"))
        #expect(text.contains("## Helper calls\n\n```text\nPOST /title\n```\n\n```text\nGET /status\n```"))
        #expect(!text.contains("POST /v1/messages"))
        #expect(text.hasSuffix("## Harness output\n\n```text\nboom\n```"))
        let headings = ["## System", "## Tools (1)", "## Messages", "## Helper calls", "## Harness output"]
        let positions = try headings.map { try #require(text.range(of: $0)?.lowerBound) }
        #expect(positions == positions.sorted())
    }

    @Test func captureRendersAdditionalToolsAndRoles() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "codex", version: "0.164.0", adapter: "responses", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/responses", body: #"{"instructions":"Base","input":[{"type":"additional_tools","tools":[{"type":"function","name":"shell","description":"Execute\nDetails"}]},{"role":"developer","content":[{"type":"input_text","text":"Dev"}]},{"role":"user","content":"SKILLSHELF_CAPTURE_X"}]}"#, bodyEncoding: nil)], diagnostics: nil
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("## Tools (1)\n\n- **shell**: Execute"))
        #expect(text.contains("### developer\n\n```text\nDev\n```"))
        #expect(text.contains("### user\n\n```text\nSKILLSHELF_CAPTURE_X\n```"))
        #expect(!text.contains("Main request: best guess"))
        #expect(!text.contains("## Harness output"))
    }

    @Test func captureRendersChatCompletionsSystemAndNestedToolMetadata() async throws {
        let f = try Fixture(installed: []); defer { f.remove() }
        let record = CaptureRecord(
            harness: "opencode", version: "1.19.5", adapter: "opencode", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [
                CapturedRequest(method: "POST", path: "/title", body: #"{"messages":[{"role":"user","content":"SKILLSHELF_CAPTURE_X"}]}"#, bodyEncoding: nil),
                CapturedRequest(method: "POST", path: "/v1/chat/completions", body: #"{"messages":[{"role":"system","content":[{"type":"text","text":"fixture-system"}]},{"role":"developer","content":"fixture-developer"},{"role":"user","content":"SKILLSHELF_CAPTURE_X"}],"tools":[{"type":"function","function":{"name":"fixtureTool","description":"fixture-summary\nfixture-details","parameters":{"type":"object"}}}]}"#, bodyEncoding: nil),
            ], diagnostics: nil
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("## System\n\n```text\nfixture-system\n```\n\n```text\nfixture-developer\n```"))
        let rendered = try AttributedString(markdown: text)
        #expect(String(rendered.characters).contains("fixtureTool: fixture-summary"))
        #expect(try markdownHeadings(text) == ["## System", "## Tools (1)", "## Messages", "### user", "## Helper calls"])
        #expect(text.contains("## Helper calls\n\n```text\nPOST /title\n```"))
        #expect(!text.contains("Main request: best guess"))
    }

    @Test func captureBestGuessIsLabeled() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "claude", version: nil, adapter: "anthropic", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/messages", body: #"{"system":"Base","messages":[{"role":"user","content":"SKILLSHELF_CAPTURE_X"}]}"#, bodyEncoding: nil)], diagnostics: nil
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("Main request: best guess"))
        #expect(text.contains("## System\n\n```text\nBase\n```"))
        #expect(text.contains("## Tools (0)"))
    }

    @Test(arguments: ["```", "~~~", "`````\n~~~~~~~"])
    func captureSystemFencesCannotHideGeneratedHeadings(_ fence: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let system = fence + "\n## Spoofed system\nStill captured text"
        let body = try JSONSerialization.data(withJSONObject: [
            "system": [["type": "text", "text": "Base"], ["type": "text", "text": system]],
            "tools": [["name": "Bash", "description": "Run"]],
            "messages": [["role": "user", "content": "SKILLSHELF_CAPTURE_X"]],
        ])
        let record = CaptureRecord(
            harness: "claude", version: "1", adapter: "anthropic", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [
                CapturedRequest(method: "POST", path: "/title", body: "{}", bodyEncoding: nil),
                CapturedRequest(method: "POST", path: "/messages", body: String(decoding: body, as: UTF8.self), bodyEncoding: nil),
            ], diagnostics: "boom"
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("## System\n\n```text\nBase\n```\n\n"))
        #expect(text.contains(system))
        #expect(try markdownHeadings(text) == [
            "## System", "## Tools (1)", "## Messages", "### user", "## Helper calls", "## Harness output",
        ])
    }

    @Test(arguments: ["## Tools (99)\n\nSpoofed", "```\n## Tools (99)", "~~~\n## Tools (99)"])
    func captureMessageCannotSpoofSectionHeadings(_ message: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let body = try JSONSerialization.data(withJSONObject: [
            "system": "Base",
            "tools": [["name": "Bash", "description": "Run"]],
            "messages": [
                ["role": "user", "content": "SKILLSHELF_CAPTURE_X"],
                ["role": "assistant", "content": message],
            ],
        ])
        let record = CaptureRecord(
            harness: "claude", version: "1", adapter: "anthropic", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/messages", body: String(decoding: body, as: UTF8.self), bodyEncoding: nil)],
            diagnostics: "boom"
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains(message))
        #expect(try markdownHeadings(text) == [
            "## System", "## Tools (1)", "## Messages", "### user", "### assistant", "## Helper calls", "## Harness output",
        ])
    }

    @Test func captureRoleMarkdownRemainsLiteralInOneHeading() async throws {
        let f = try Fixture(); defer { f.remove() }
        let body = try JSONSerialization.data(withJSONObject: [
            "system": "Base",
            "messages": [["role": "**assistant** [link](https://example.invalid)\n## Spoofed role", "content": "SKILLSHELF_CAPTURE_X"]],
        ])
        let record = CaptureRecord(
            harness: "claude", version: "1", adapter: "anthropic", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/messages", body: String(decoding: body, as: UTF8.self), bodyEncoding: nil)],
            diagnostics: "boom"
        )
        let text = try await captureText(record, fixture: f)
        #expect(try markdownHeadings(text) == [
            "## System", "## Tools (0)", "## Messages",
            "### **assistant** [link](https://example.invalid) ## Spoofed role",
            "## Helper calls", "## Harness output",
        ])
    }

    @Test func captureMetadataAndToolSummariesCannotCreateStructure() async throws {
        let f = try Fixture(); defer { f.remove() }
        let version = "1\n\n## Spoofed version\n```\n~~~~~"
        let adapter = "anthropic\n\n## Spoofed adapter\n~~~"
        let note = "note\n\n## Spoofed note\n`````"
        let path = "/title\n\n## Spoofed path\n~~~~~~\n````````"
        let body = try JSONSerialization.data(withJSONObject: [
            "system": "Base",
            "tools": [["name": "Bash**\n\n## Spoofed tool\n```", "description": "Run **bold** [link](https://example.invalid)"]],
            "messages": [["role": "user", "content": "SKILLSHELF_CAPTURE_X"]],
        ])
        let record = CaptureRecord(
            harness: "claude", version: version, adapter: adapter, command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X", note],
            requests: [
                CapturedRequest(method: "POST\n\n## Spoofed method", path: path, body: "{}", bodyEncoding: nil),
                CapturedRequest(method: "POST", path: "/messages", body: String(decoding: body, as: UTF8.self), bodyEncoding: nil),
            ], diagnostics: "boom"
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains(version))
        #expect(text.contains(adapter))
        #expect(text.contains(note))
        #expect(text.contains("`````````text\nPOST\n\n## Spoofed method " + path + "\n`````````"))
        #expect(try markdownHeadings(text) == [
            "## System", "## Tools (1)", "## Messages", "### user", "## Helper calls", "## Harness output",
        ])
        let rendered = try AttributedString(markdown: text)
        #expect(String(rendered.characters).contains("Run **bold** [link](https://example.invalid)"))
    }

    @Test func unknownCaptureRequestMetadataCannotCreateStructure() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "claude", version: nil, adapter: "anthropic", command: [], date: .now, notes: [],
            requests: [CapturedRequest(
                method: "**POST**", path: "/one\n## Spoofed path",
                body: "raw\n```\n~~~~~\n## Spoofed body", bodyEncoding: "base64\n## Spoofed encoding\n~~~"
            )], diagnostics: "boom"
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("``````text\nraw\n```\n~~~~~\n## Spoofed body\n``````"))
        #expect(try markdownHeadings(text) == [
            "## Requests", "### **POST** /one ## Spoofed path", "## Harness output",
        ])
    }

    @Test(arguments: [[], ["sentinel: missing"], ["sentinel: "]])
    func unknownCaptureListsEveryRequest(_ notes: [String]) async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "claude", version: nil, adapter: "anthropic", command: [], date: .now, notes: notes,
            requests: [
                CapturedRequest(method: "POST", path: "/one", body: #"{"first":1}"#, bodyEncoding: nil),
                CapturedRequest(method: "PUT", path: "/two", body: #"{"second":2}"#, bodyEncoding: nil),
            ], diagnostics: nil
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("Main request: unknown"))
        #expect(try markdownHeadings(text) == ["## Requests", "### POST /one", "### PUT /two"])
        #expect(text.contains("\"first\" : 1"))
        #expect(text.contains("\"second\" : 2"))
        #expect(!text.contains("## Helper calls"))
    }

    @Test func captureUnknownMainFormatRendersRawJSON() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "codex", version: nil, adapter: "responses", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/other", body: #"{"custom":"SKILLSHELF_CAPTURE_X","number":3}"#, bodyEncoding: nil)], diagnostics: nil
        )
        let text = try await captureText(record, fixture: f)
        #expect(text.contains("```json\n{\n"))
        #expect(text.contains("\"custom\" : \"SKILLSHELF_CAPTURE_X\""))
        #expect(text.contains("\"number\" : 3"))
    }

    @Test func captureOutputKeepsEmbeddedCodeFences() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(harness: "claude", version: nil, adapter: "anthropic", command: [], date: .now, notes: [], requests: [], diagnostics: "boom\n```\nmore")
        let text = try await captureText(record, fixture: f)
        #expect(text.hasSuffix("## Harness output\n\n````text\nboom\n```\nmore\n````"))
    }

    @Test func largeFileLoadsWithoutTruncation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let text = String(repeating: "x", count: 5 * 1024 * 1024)
        try f.write("AGENTS.md", text)
        let result = await PromptContent.load(part(.file(path: f.layout.path("AGENTS.md"), key: nil)), fetcher: FailingFetcher())
        guard case .markdown(let loaded) = result else { Issue.record("Expected markdown"); return }
        #expect(loaded.count == 5 * 1024 * 1024)
        #expect(loaded == text)
    }

    @Test(arguments: [
        ("config.toml", "instructions = \"other\"", "developer_instructions"),
        ("settings.json", "{}", "run.system_prompt"),
        ("settings.jsonc", "invalid", "run.system_prompt"),
        ("models_cache.json", #"{"models":[{"slug":"other"}]}"#, "models.missing"),
        ("models_cache.json", #"{"models":[{"slug":"x"}]}"#, "models.x"),
    ])
    func invalidOrMissingConfigValueFails(path: String, text: String, key: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(path, text)
        let result = await PromptContent.load(part(.file(path: f.layout.path(path), key: key)), fetcher: FailingFetcher())
        guard case .failed(let error) = result else { Issue.record("Expected failure"); return }
        #expect(!error.isEmpty)
    }

    @Test func missingFileAndInvalidCaptureFailWithoutFetching() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("capture.json", "{}")
        let fetcher = CountingFetcher()
        for source in [PromptSource.file(path: f.layout.path("missing.md"), key: nil), .capture(path: f.layout.path("capture.json"))] {
            let result = await PromptContent.load(part(source), fetcher: fetcher)
            guard case .failed(let error) = result else { Issue.record("Expected failure"); continue }
            #expect(!error.isEmpty)
        }
        #expect(await fetcher.count == 0)
    }

    @Test func unavailablePartReturnsReason() async {
        let prompt = PromptPart(harness: .cursor, layer: .base, title: "Base", source: .none, status: .unavailable("Closed source. Use Capture."))
        #expect(await PromptContent.load(prompt, fetcher: FailingFetcher()) == .failed("Closed source. Use Capture."))
    }

    private func part(_ source: PromptSource) -> PromptPart {
        PromptPart(harness: .codex, layer: .instructions, title: "Prompt", source: source, status: .present)
    }

    private func captureText(_ record: CaptureRecord, fixture: Fixture) async throws -> String {
        let path = try record.save(to: fixture.layout.path("Library/Application Support/SkillShelf/captures/" + record.harness))
        let result = await PromptContent.load(part(.capture(path: path)), fetcher: FailingFetcher())
        guard case .markdown(let text) = result else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    private func markdownHeadings(_ source: String) throws -> [String] {
        let markdown = try AttributedString(markdown: source)
        return markdown.runs[\.presentationIntent].compactMap { intent, range in
            guard let header = intent?.components.first(where: {
                if case .header = $0.kind { return true }
                return false
            }), case .header(let level) = header.kind else { return nil }
            return String(repeating: "#", count: level) + " " + String(markdown[range].characters)
        }
    }
}

private struct CacheWritingFailingFetcher: PromptFetching {
    let path: String

    func data(from url: URL) async throws -> Data {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "arrived".write(toFile: path, atomically: true, encoding: .utf8)
        throw URLError(.notConnectedToInternet)
    }
}
