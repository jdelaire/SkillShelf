import Foundation
import Testing
@testable import SkillShelf
@testable import SkillShelfCore

@MainActor
struct PromptStateTests {
    @Test func baseRechecksVersionAndReloadsOnlyWhenNeeded() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"first"}]}"#)
        let runner = VersionRunner()
        let state = state(f, runner: runner)

        await state.loadBase(.codex)
        #expect(state.parts(for: .codex).map(\.title) == ["first"])
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"second"}]}"#)
        await state.loadBase(.codex)
        #expect(state.parts(for: .codex).map(\.title) == ["first"])
        await state.loadBase(.codex, force: true)
        #expect(state.parts(for: .codex).map(\.title) == ["second"])
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"third"}]}"#)
        await runner.setVersion("0.165.0")
        await state.loadBase(.codex)

        #expect(state.parts(for: .codex).map(\.title) == ["third"])
        #expect(state.parts(for: .codex).first?.version == "0.165.0")
        #expect(await runner.calls == 4)
    }

    @Test func partsCombineInstructionsBaseAndCapturesAndResolveIDs() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        try f.write(".codex/AGENTS.md", "Instructions")
        try f.write(".codex/models_cache.json", #"{"models":[{"slug":"model"}]}"#)
        let state = state(f, runner: StubRunner(output: "0.164.0"))
        state.instructions = f.snapshot().prompts
        let path = try CaptureRecord(
            harness: "codex", version: "0.164.0", adapter: "codex", command: [], date: .now,
            notes: [], requests: [], diagnostics: nil
        ).save(to: f.layout.path("captures/codex"))

        await state.loadBase(.codex)
        await state.loadCaptures(.codex)
        let parts = state.parts(for: .codex)

        #expect(parts.map(\.layer) == [.instructions, .base, .capture])
        #expect(parts.last?.source == .capture(path: path))
        #expect(parts.allSatisfy { state.part(id: $0.id) == $0 })
        #expect(state.part(id: "missing") == nil)
        #expect(state.parts(for: .claude).isEmpty)
    }

    @Test func olderBaseLoadCannotReplaceNewerVersion() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        let runner = BaseGateRunner()
        let state = state(f, runner: runner)
        let older = Task { await state.loadBase(.codex) }
        var started = runner.started.makeAsyncIterator()
        _ = await started.next()
        guard case .loading = state.base[.codex] else {
            await runner.release()
            await older.value
            Issue.record("Expected initial loading state")
            return
        }
        await state.loadBase(.codex)
        await runner.release()
        await older.value

        #expect(state.parts(for: .codex).first?.version == "0.165.0")
    }

    @Test func successfulCaptureReloadsIndexAndInvalidatesContent() async throws {
        let f = try Fixture(installed: [.claude]); defer { f.remove() }
        let engine = PromptCapture(
            launcher: LocalCaptureLauncher(), resolveTool: { _ in "/fake/claude" },
            loginEnvironment: { ["HOME": f.home] },
            capturesRoot: f.layout.path("captures"), tempRoot: f.layout.path("temp")
        )
        let state = PromptState(
            layout: f.layout, runner: StubRunner(output: "2.1.312"), fetcher: FailingFetcher(),
            cacheRoot: f.layout.path("cache"), capturesRoot: f.layout.path("captures"),
            environment: [:], capture: engine
        )
        state.captureError[.claude] = "Previous failure"

        await state.capture(.claude)

        #expect(state.captureError[.claude] == nil)
        #expect(state.capturing == nil)
        #expect(state.contentGeneration == 1)
        let part = try #require(state.captures[.claude]?.first)
        #expect(part.title.hasSuffix("Main request: found"))
        #expect(part.version == "2.1.312")
        guard case .capture(let path) = part.source else {
            Issue.record("Expected saved capture source")
            return
        }
        #expect(try CaptureRecord.load(path).requests.count == 1)
    }

    @Test func captureReportsUnavailableAndMissingToolsAndPreventsOverlap() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        let gate = CaptureResolutionGate()
        let engine = PromptCapture(
            resolveTool: { _ in await gate.resolve() }, loginEnvironment: { [:] },
            capturesRoot: f.layout.path("captures"), tempRoot: f.layout.path("temp")
        )
        let state = PromptState(
            layout: f.layout, runner: StubRunner(output: "0.164.0"), fetcher: FailingFetcher(),
            cacheRoot: f.layout.path("cache"), capturesRoot: f.layout.path("captures"),
            environment: [:], capture: engine
        )
        await state.capture(.cursor)
        #expect(state.captureError[.cursor] == "Prompt is assembled on Cursor's servers")
        #expect(state.capturing == nil)
        let task = Task { await state.capture(.codex) }
        var started = gate.started.makeAsyncIterator()
        _ = await started.next()
        #expect(state.capturing == .codex)
        await state.capture(.claude)
        #expect(state.capturing == .codex)
        #expect(state.captureError[.claude] == nil)
        await gate.release()
        await task.value

        #expect(state.capturing == nil)
        #expect(state.captureError[.codex] == CaptureError.notInstalled.localizedDescription)
        #expect(state.contentGeneration == 1)
    }

    private func state(_ f: Fixture, runner: any CommandRunning) -> PromptState {
        PromptState(
            layout: f.layout, runner: runner, fetcher: FailingFetcher(),
            cacheRoot: f.layout.path("cache"), capturesRoot: f.layout.path("captures"), environment: [:]
        )
    }
}

@MainActor
struct AppModelPromptTests {
    @Test func refreshCoalescesRequestsAndPreservesSkillsState() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        try f.skill(".codex/skills/alpha")
        try f.write(".codex/AGENTS.md", "Instructions")
        let runner = ScanGateRunner()
        let model = AppModel(layout: f.layout, runner: runner)
        model.snapshot = f.snapshot()
        let entry = try #require(model.snapshot.entries.first)
        model.selection = entry.id
        model.requestDelete(entry)
        model.requestPush(entry)
        model.prompts.instructions = model.snapshot.prompts
        let prompt = try #require(model.prompts.parts(for: .codex).first)
        model.prompts.selection = prompt.id
        let scan = Task { await model.refresh() }
        var started = runner.started.makeAsyncIterator()
        _ = await started.next()

        await model.refresh()
        await model.refresh()
        await model.refresh()
        #expect(await runner.calls == 1)
        #expect(model.isScanning)
        await runner.release()
        await scan.value

        #expect(await runner.calls == 2)
        #expect(model.snapshot.generation == 2)
        #expect(!model.isScanning)
        #expect(model.selection == entry.id)
        #expect(model.deleteRequest?.entry.id == entry.id)
        #expect(model.pushRequest?.entry.id == entry.id)
        #expect(model.prompts.selection == prompt.id)
        #expect(model.prompts.contentGeneration == 2)
        #expect(model.prompts.instructions == model.snapshot.prompts)
        model.sidebar = .prompts(.codex)
        #expect(model.rows.isEmpty)
        #expect(model.selection == nil)
        #expect(model.prompts.selection == prompt.id)
    }

    @Test func refreshKeepsBaseSelectionAndClearsRemovedInstructionSelection() async throws {
        let f = try Fixture(installed: [.codex]); defer { f.remove() }
        try f.write(".codex/config.toml", "instructions = \"inline\"")
        let prompts = PromptState(
            layout: f.layout, runner: StubRunner(output: "0.164.0"), fetcher: FailingFetcher(),
            cacheRoot: f.layout.path("cache"), capturesRoot: f.layout.path("captures"), environment: [:]
        )
        let model = AppModel(layout: f.layout, runner: StubRunner(output: "{}"), prompts: prompts)
        await model.refresh()
        let inline = try #require(prompts.parts(for: .codex).first { $0.title.contains("instructions") })
        prompts.selection = inline.id
        try f.write(".codex/config.toml", "")
        await model.refresh()
        #expect(prompts.selection == nil)
        await prompts.loadBase(.codex)
        let base = try #require(prompts.parts(for: .codex).first { $0.layer == .base })
        prompts.selection = base.id

        await model.refresh()

        #expect(prompts.selection == base.id)
        #expect(prompts.part(id: base.id) == base)
        #expect(prompts.contentGeneration == 3)
    }
}

private actor VersionRunner: CommandRunning {
    private var version = "0.164.0"
    private(set) var calls = 0

    func setVersion(_ value: String) { version = value }

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        calls += 1
        return CommandResult(status: 0, output: version, error: "")
    }
}

private actor ScanGateRunner: CommandRunning {
    nonisolated let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation {
                releaseWaiter = $0
                continuation.yield(())
            }
        }
        return CommandResult(status: 0, output: "{}", error: "")
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
        continuation.finish()
    }
}

private actor BaseGateRunner: CommandRunning {
    nonisolated let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var calls = 0

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation {
                releaseWaiter = $0
                continuation.yield(())
            }
            return CommandResult(status: 0, output: "0.164.0", error: "")
        }
        return CommandResult(status: 0, output: "0.165.0", error: "")
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
        continuation.finish()
    }
}

private struct LocalCaptureLauncher: CaptureProcessLaunching {
    func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle {
        guard let base = environment["ANTHROPIC_BASE_URL"], let port = URL(string: base)?.port,
              let sentinel = argv.last else { throw URLError(.badURL) }
        let request = Task {
            let body = Data(#"{"messages":[{"role":"user","content":"\#(sentinel)"}],"tools":[{"name":"shell"}]}"#.utf8)
            _ = try await rawPost(port: UInt16(port), headers: [], body: body)
        }
        return LocalCaptureProcess(request: request)
    }
}

private struct LocalCaptureProcess: CaptureProcessHandle {
    let pid: Int32 = 0
    let request: Task<Void, Error>

    func terminate() async {}
    func exitStatus() async -> Int32 {
        _ = try? await request.value
        return 0
    }
    func diagnostics() async -> (stdout: String, stderr: String) { ("", "") }
}

private actor CaptureResolutionGate {
    nonisolated let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var releaseWaiter: CheckedContinuation<String?, Never>?

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    func resolve() async -> String? {
        await withCheckedContinuation {
            releaseWaiter = $0
            continuation.yield(())
        }
    }

    func release() {
        releaseWaiter?.resume(returning: nil)
        releaseWaiter = nil
        continuation.finish()
    }
}
