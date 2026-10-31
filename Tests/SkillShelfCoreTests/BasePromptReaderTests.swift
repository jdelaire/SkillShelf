import Foundation
import Testing
@testable import SkillShelfCore

struct BasePromptReaderTests {
    @Test func versionParsesFirstSemver() {
        #expect(BasePromptReader.version(from: "codex-cli 0.164.0\n") == "0.164.0")
        #expect(BasePromptReader.version(from: "2.1.312 (Claude Code)") == "2.1.312")
        #expect(BasePromptReader.version(from: "v1.19.5-beta.2+build.4 other 2.0.0") == "1.19.5-beta.2+build.4")
        #expect(BasePromptReader.version(from: "unknown") == nil)
    }

    @Test func urlsArePinnedToVersion() {
        #expect(BasePromptReader.openCodeFileURL(version: "1.19.5", name: "codex.txt").absoluteString == "https://raw.githubusercontent.com/anomalyco/opencode/v1.19.5/packages/opencode/src/session/prompt/codex.txt")
        #expect(BasePromptReader.openCodeListURL(version: "1.19.5").absoluteString == "https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/session/prompt?ref=v1.19.5")
        #expect(BasePromptReader.codexFallbackURL(version: "0.164.0").absoluteString == "https://raw.githubusercontent.com/openai/codex/rust-v0.164.0/codex-rs/models-manager/prompt.md")
        #expect(BasePromptReader.cachePath(cacheRoot: "/tmp/prompts", harness: .opencode, version: "1.19.5", file: "codex.txt") == "/tmp/prompts/opencode/1.19.5/codex.txt")
    }

    @Test(arguments: [[:], ["CODEX_HOME": ""]])
    func codexModelsComeFromCacheWithConfiguredFirst(_ environment: [String: String]) async throws {
        let f = try Fixture(); defer { f.remove() }
        let cache = #"{"fetched_at":"2026-10-30T00:00:00Z","etag":"test","client_version":"0.164.0","identity":"fixture","models":[{"slug":"a","model_messages":{"persistent_instructions":"p"}},{"slug":"b","model_messages":{"instructions_template":"t","approvals":{"on_request":"confirm"}}}]}"#
        try f.write(".codex/models_cache.json", cache)
        try f.write(".codex/config.toml", "model = \"b\"")
        let fetcher = CountingFetcher()
        let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "codex-cli 0.164.0"), fetcher: fetcher, cacheRoot: f.layout.path("cache"), environment: environment)
        #expect(result.version == "0.164.0")
        #expect(result.parts.map(\.title) == ["b", "a"])
        #expect(result.parts[0].notes == ["Configured model"])
        #expect(result.parts[1].notes.isEmpty)
        #expect(result.parts.map(\.source) == [
            .file(path: f.layout.path(".codex/models_cache.json"), key: "models.b"),
            .file(path: f.layout.path(".codex/models_cache.json"), key: "models.a"),
        ])
        #expect(result.parts.allSatisfy { $0.harness == .codex && $0.layer == .base && $0.status == .present && $0.version == "0.164.0" })
        #expect(await fetcher.count == 0)
        #expect(try String(contentsOfFile: f.layout.path(".codex/models_cache.json"), encoding: .utf8) == cache)
        #expect(try String(contentsOfFile: f.layout.path(".codex/config.toml"), encoding: .utf8) == "model = \"b\"")
    }

    @Test func codexModelsHonorCustomHomeAndConfiguredModel() async throws {
        let f = try Fixture(); defer { f.remove() }
        let cache = #"{"models":[{"slug":"a"},{"slug":"b"}]}"#
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"default"}]}"#)
        try f.write(".codex/config.toml", "model = \"a\"")
        try f.write("custom/models_cache.json", cache)
        try f.write("custom/config.toml", "model = \"b\"")
        let fetcher = CountingFetcher()
        let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "0.164.0"), fetcher: fetcher, cacheRoot: f.layout.path("cache"), environment: ["CODEX_HOME": f.layout.path("custom")])
        #expect(result.version == "0.164.0")
        #expect(result.parts.map(\.title) == ["b", "a"])
        #expect(result.parts.first?.notes == ["Configured model"])
        #expect(result.parts.dropFirst().allSatisfy { $0.notes.isEmpty })
        #expect(result.parts.map(\.source) == [
            .file(path: f.layout.path("custom/models_cache.json"), key: "models.b"),
            .file(path: f.layout.path("custom/models_cache.json"), key: "models.a"),
        ])
        #expect(result.parts.allSatisfy { $0.status == .present && $0.version == "0.164.0" })
        #expect(await fetcher.count == 0)
        #expect(try String(contentsOfFile: f.layout.path("custom/models_cache.json"), encoding: .utf8) == cache)
        #expect(try String(contentsOfFile: f.layout.path("custom/config.toml"), encoding: .utf8) == "model = \"b\"")
    }

    @Test func codexQuotedProfileModelDoesNotOverrideConfiguredModel() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"profile"},{"slug":"global"}]}"#)
        try f.write(".codex/config.toml", #"""
        model = "global"
        [profiles."review"]
        model = "profile"
        """#)
        let result = await BasePromptReader.read(
            harness: .codex, layout: f.layout, runner: StubRunner(output: "0.164.0"),
            fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"), environment: [:]
        )
        #expect(result.parts.map(\.title) == ["global", "profile"])
        #expect(result.parts.first?.notes == ["Configured model"])
        #expect(result.parts.last?.notes.isEmpty == true)
    }

    @Test(arguments: ["", "{}", "{\"models\":[]}", "{\"models\":{}}", "invalid"])
    func codexMissingOrUnreadableCacheFallsBackLazily(_ contents: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        if !contents.isEmpty { try f.write(".codex/models_cache.json", contents) }
        let fetcher = CountingFetcher()
        let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "codex-cli 0.164.0"), fetcher: fetcher, cacheRoot: f.layout.path("cache"), environment: [:])
        let part = try #require(result.parts.only)
        #expect(part.title == "prompt.md")
        #expect(part.source == .remote(
            url: URL(string: "https://raw.githubusercontent.com/openai/codex/rust-v0.164.0/codex-rs/models-manager/prompt.md")!,
            cache: f.layout.path("cache/codex/0.164.0/prompt.md")
        ))
        #expect(part.status == .present)
        #expect(part.version == "0.164.0")
        #expect(await fetcher.count == 0)
    }

    @Test func codexDefaultCacheRootUsesSkillShelfCacheDirectory() async throws {
        let f = try Fixture(); defer { f.remove() }
        let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "0.164.0"), fetcher: FailingFetcher(), environment: [:])
        guard case .remote(_, let cache) = result.parts.first?.source else {
            Issue.record("expected remote fallback"); return
        }
        #expect(cache == NSHomeDirectory() + "/Library/Caches/SkillShelf/prompts/codex/0.164.0/prompt.md")
    }

    @Test func cachedOpenCodeFileSkipsFetch() async throws {
        let f = try Fixture(); defer { f.remove() }
        let cache = f.layout.path("cache")
        try f.write("cache/opencode/1.19.5/index.json", #"["codex.txt"]"#)
        try f.write("cache/opencode/1.19.5/codex.txt", "cached")
        let fetcher = CountingFetcher()
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: fetcher, cacheRoot: cache)
        #expect(result.parts.map(\.title) == ["codex.txt"])
        #expect(result.parts.first?.status == .present)
        #expect(await fetcher.count == 0)
        #expect(try String(contentsOfFile: f.layout.path("cache/opencode/1.19.5/codex.txt"), encoding: .utf8) == "cached")
    }

    @Test func openCodeListingCachesNamesAndDefersBodies() async throws {
        let f = try Fixture(); defer { f.remove() }
        let fetcher = StubFetcher(#"[{"name":"codex.txt","type":"file"},{"name":"README.md","type":"file"},{"name":"nested.txt","type":"dir"},{"name":"../escape.txt","type":"file"},{"name":"claude.txt","type":"file"}]"#)
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: fetcher, cacheRoot: f.layout.path("cache"))
        #expect(Set(result.parts.map(\.title)) == ["codex.txt", "claude.txt"])
        #expect(await fetcher.urls.map(\.absoluteString) == ["https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/session/prompt?ref=v1.19.5"])
        let codex = try #require(result.parts.first { $0.title == "codex.txt" })
        #expect(codex.source == .remote(
            url: URL(string: "https://raw.githubusercontent.com/anomalyco/opencode/v1.19.5/packages/opencode/src/session/prompt/codex.txt")!,
            cache: f.layout.path("cache/opencode/1.19.5/codex.txt")
        ))
        #expect(result.parts.allSatisfy { $0.harness == .opencode && $0.layer == .base && $0.status == .present && $0.version == "1.19.5" })
        let index = try Data(contentsOf: URL(fileURLWithPath: f.layout.path("cache/opencode/1.19.5/index.json")))
        #expect(Set(try JSONDecoder().decode([String].self, from: index)) == ["codex.txt", "claude.txt"])
        #expect(!FileManager.default.fileExists(atPath: f.layout.path("cache/opencode/1.19.5/codex.txt")))
        let cached = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
        #expect(cached.parts == result.parts)
    }

    @Test func openCodeCacheIsVersionSpecific() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("cache/opencode/1.19.4/index.json", #"["old.txt"]"#)
        let fetcher = StubFetcher(#"[{"name":"new.txt","type":"file"}]"#)
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: fetcher, cacheRoot: f.layout.path("cache"))
        #expect(result.parts.map(\.title) == ["new.txt"])
        #expect(await fetcher.urls.count == 1)
        #expect(try String(contentsOfFile: f.layout.path("cache/opencode/1.19.4/index.json"), encoding: .utf8) == #"["old.txt"]"#)
    }

    @Test func failedListingIsRetryableUnavailable() async throws {
        let f = try Fixture(); defer { f.remove() }
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
        #expect(result.version == "1.19.5")
        let part = try #require(result.parts.only)
        guard case .unavailable(let reason) = part.status else { Issue.record("expected unavailable"); return }
        #expect(reason.hasPrefix("Could not list prompts:"))
        #expect(part.source == .none)
        #expect(!FileManager.default.fileExists(atPath: f.layout.path("cache/opencode/1.19.5/index.json")))
        let retried = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: StubFetcher(#"[{"name":"codex.txt","type":"file"}]"#), cacheRoot: f.layout.path("cache"))
        #expect(retried.parts.map(\.title) == ["codex.txt"])
        #expect(retried.parts.first?.status == .present)
    }

    @Test func malformedListingDoesNotPoisonCache() async throws {
        let f = try Fixture(); defer { f.remove() }
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: StubFetcher(#"{"message":"API rate limit exceeded"}"#), cacheRoot: f.layout.path("cache"))
        guard case .unavailable(let reason) = result.parts.first?.status else { Issue.record("expected unavailable"); return }
        #expect(reason.hasPrefix("Could not list prompts:"))
        #expect(!FileManager.default.fileExists(atPath: f.layout.path("cache/opencode/1.19.5/index.json")))
    }

    @Test(arguments: [
        ("cache/opencode", "cache/opencode"),
        ("cache/opencode/1.19.5/index.json/blocker", "cache/opencode/1.19.5/index.json"),
    ])
    func openCodeListingPersistenceFailureIsRetryableUnavailable(blocker: String, obstruction: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(blocker, "cache blocker")
        let fetcher = StubFetcher(#"[{"name":"codex.txt","type":"file"}]"#)
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: fetcher, cacheRoot: f.layout.path("cache"))
        #expect(result.version == "1.19.5")
        let part = try #require(result.parts.only)
        guard case .unavailable(let reason) = part.status else { Issue.record("expected unavailable for cache persistence failure"); return }
        #expect(reason.hasPrefix("Could not list prompts:"))
        #expect(part.source == .none)
        #expect(part.version == "1.19.5")
        #expect(try String(contentsOfFile: f.layout.path(blocker), encoding: .utf8) == "cache blocker")

        try FileManager.default.removeItem(atPath: f.layout.path(obstruction))
        let retried = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: fetcher, cacheRoot: f.layout.path("cache"))
        #expect(retried.parts.map(\.title) == ["codex.txt"])
        #expect(retried.parts.first?.status == .present)
        let index = try Data(contentsOf: URL(fileURLWithPath: f.layout.path("cache/opencode/1.19.5/index.json")))
        #expect(try JSONDecoder().decode([String].self, from: index) == ["codex.txt"])
        let cached = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
        #expect(cached.parts == retried.parts)
    }

    @Test func unreadableListingCacheIsRefetched() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("cache/opencode/1.19.5/index.json", "invalid")
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "1.19.5"), fetcher: StubFetcher(#"[{"name":"codex.txt","type":"file"}]"#), cacheRoot: f.layout.path("cache"))
        #expect(result.parts.map(\.title) == ["codex.txt"])
        let data = try Data(contentsOf: URL(fileURLWithPath: f.layout.path("cache/opencode/1.19.5/index.json")))
        #expect(try JSONDecoder().decode([String].self, from: data) == ["codex.txt"])
    }

    @Test(arguments: [HarnessID.claude, .cursor, .grok, .antigravity, .muse])
    func closedHarnessIsUnavailable(_ harness: HarnessID) async throws {
        let f = try Fixture(); defer { f.remove() }
        let fetcher = CountingFetcher()
        let result = await BasePromptReader.read(harness: harness, layout: f.layout, runner: StubRunner(output: "2.1.312"), fetcher: fetcher, cacheRoot: f.layout.path("cache"))
        #expect(result.version == "2.1.312")
        #expect(result.parts.map(\.status) == [.unavailable("Closed source. Use Capture.")])
        #expect(result.parts.first?.source == PromptSource.none)
        #expect(await fetcher.count == 0)
    }

    @Test func versionFailureIsReported() async throws {
        let f = try Fixture(); defer { f.remove() }
        let fetcher = CountingFetcher()
        let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: StubRunner(output: "0.164.0", error: "boom\nmore detail", status: 1), fetcher: fetcher, cacheRoot: f.layout.path("cache"))
        #expect(result.version == nil)
        #expect(result.parts.map(\.status) == [.unavailable("Could not read version: boom")])
        #expect(await fetcher.count == 0)
    }

    @Test func unparseableVersionIsReported() async throws {
        let f = try Fixture(); defer { f.remove() }
        let result = await BasePromptReader.read(harness: .opencode, layout: f.layout, runner: StubRunner(output: "unknown version\nmore output"), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
        #expect(result.version == nil)
        #expect(result.parts.map(\.status) == [.unavailable("Could not read version: unknown version")])
    }

    @Test func thrownVersionFailureIsReported() async throws {
        let f = try Fixture(); defer { f.remove() }
        let result = await BasePromptReader.read(harness: .codex, layout: f.layout, runner: ThrowingRunner(), fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"))
        #expect(result.version == nil)
        #expect(result.parts.map(\.status) == [.unavailable("Could not read version: codex is not on your login PATH.")])
    }

    @Test(arguments: [
        (HarnessID.claude, "claude"), (.codex, "codex"), (.cursor, "cursor"),
        (.opencode, "opencode"), (.grok, "grok"), (.antigravity, "agy"), (.muse, "muse"),
    ])
    func versionUsesHarnessCommand(_ harness: HarnessID, tool: String) async throws {
        let f = try Fixture(); defer { f.remove() }
        let runner = RecordingRunner()
        _ = await BasePromptReader.read(harness: harness, layout: f.layout, runner: runner, fetcher: FailingFetcher(), cacheRoot: f.layout.path("cache"), environment: [:])
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == tool)
        #expect(calls.first?.1 == ["--version"])
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
