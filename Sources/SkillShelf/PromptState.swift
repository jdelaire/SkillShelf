import Foundation
import Observation
import SkillShelfCore

@MainActor
@Observable
final class PromptState {
    enum BaseState {
        case loading
        case loaded(BasePrompts)
    }

    var instructions: [HarnessID: [PromptPart]] = [:]
    var base: [HarnessID: BaseState] = [:]
    var captures: [HarnessID: [PromptPart]] = [:]
    var selection: PromptPart.ID?
    var contentGeneration = 0
    var capturing: HarnessID?
    var captureError: [HarnessID: String] = [:]

    private let layout: Layout
    private let runner: any CommandRunning
    private let fetcher: any PromptFetching
    private let cacheRoot: String
    private let capturesRoot: String
    private let environment: [String: String]
    private let captureRunner: PromptCapture
    @ObservationIgnored private var baseGenerations: [HarnessID: Int] = [:]
    @ObservationIgnored private var captureGenerations: [HarnessID: Int] = [:]

    init(
        layout: Layout,
        runner: any CommandRunning,
        fetcher: any PromptFetching = URLSessionFetcher(),
        cacheRoot: String? = nil,
        capturesRoot: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        capture: PromptCapture? = nil
    ) {
        self.layout = layout
        self.runner = runner
        self.fetcher = fetcher
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkillShelf/prompts", isDirectory: true).path
        let capturesRoot = capturesRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkillShelf/captures", isDirectory: true).path
        self.capturesRoot = capturesRoot
        self.environment = environment
        let loginRunner = runner as? LoginShellRunner ?? LoginShellRunner(home: layout.home)
        captureRunner = capture ?? PromptCapture(
            resolveTool: { await loginRunner.resolve($0) },
            loginEnvironment: { await loginRunner.loginEnvironment() }, capturesRoot: capturesRoot
        )
    }

    @discardableResult
    func loadBase(_ harness: HarnessID, force: Bool = false) async -> BasePrompts {
        let current = baseGenerations[harness, default: 0] + 1
        baseGenerations[harness] = current
        let previous: BasePrompts?
        if case .loaded(let loaded) = base[harness] {
            previous = loaded
        } else {
            previous = nil
            base[harness] = .loading
        }
        let result = await BasePromptReader.read(
            harness: harness, layout: layout, runner: runner, fetcher: fetcher, cacheRoot: cacheRoot,
            environment: environment, reusing: previous, force: force
        )
        if baseGenerations[harness] == current {
            base[harness] = .loaded(result)
        }
        return result
    }

    func loadCaptures(_ harness: HarnessID) async {
        let current = captureGenerations[harness, default: 0] + 1
        captureGenerations[harness] = current
        let result = await CaptureIndex.list(harness: harness, capturesRoot: capturesRoot)
        guard captureGenerations[harness] == current else { return }
        captures[harness] = result
    }

    func capture(_ harness: HarnessID) async {
        guard capturing == nil else { return }
        guard let adapter = CaptureAdapters.adapter(for: harness) else {
            captureError[harness] = CaptureAdapters.unavailableReason(for: harness)
            return
        }
        capturing = harness
        captureError[harness] = nil
        defer {
            capturing = nil
            contentGeneration += 1
        }
        let loaded = await loadBase(harness)
        do {
            _ = try await captureRunner.run(adapter, version: loaded.version)
        } catch {
            captureError[harness] = error.localizedDescription
        }
        await loadCaptures(harness)
    }

    func parts(for harness: HarnessID) -> [PromptPart] {
        var parts = instructions[harness] ?? []
        if case .loaded(let loaded) = base[harness] { parts += loaded.parts }
        return parts + (captures[harness] ?? [])
    }

    func part(id: PromptPart.ID) -> PromptPart? {
        for harness in HarnessID.allCases {
            if let part = parts(for: harness).first(where: { $0.id == id }) { return part }
        }
        return nil
    }
}
