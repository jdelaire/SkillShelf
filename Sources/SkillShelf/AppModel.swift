import AppKit
import Observation
import SkillShelfCore

enum SidebarItem: Hashable {
    case all
    case harness(HarnessID)
    case prompts(HarnessID)
}

struct DeleteRequest: Identifiable {
    let entry: SkillEntry
    let result: DeletePlanner.Result
    var id: String { entry.id }
}

struct PushRequest: Identifiable {
    let entry: SkillEntry
    let result: PushPlanner.Result
    var id: String { entry.id }
}

@MainActor
@Observable
final class AppModel {
    let layout: Layout
    private let runner: any CommandRunning
    private let mutator: Mutator
    let prompts: PromptState

    var snapshot = Snapshot.empty
    var sidebar: SidebarItem? = .all {
        didSet { if sidebar != oldValue { selection = nil } }
    }
    var selection: String?
    var search = ""
    var isScanning = false
    var isWorking = false
    var deleteRequest: DeleteRequest?
    var pushRequest: PushRequest?
    var message: String?
    var errorMessage: String?
    private var generation = 0
    private var rescanRequested = false

    init(layout: Layout = Layout(), runner: (any CommandRunning)? = nil, prompts: PromptState? = nil) {
        self.layout = layout
        let runner = runner ?? LoginShellRunner(home: layout.home)
        self.runner = runner
        mutator = Mutator(layout: layout, runner: runner)
        self.prompts = prompts ?? PromptState(layout: layout, runner: runner)
    }

    var rows: [HarnessRow] {
        let base: [HarnessRow]
        switch sidebar {
        case .harness(let harness): base = snapshot.rows(for: harness)
        case .prompts: base = []
        case .all, nil: base = snapshot.allRows()
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.entry.name.localizedCaseInsensitiveContains(query)
                || $0.entry.description.localizedCaseInsensitiveContains(query)
                || $0.entry.entryPath.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedRow: HarnessRow? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    func count(for harness: HarnessID) -> Int {
        snapshot.rows(for: harness).count
    }

    func refresh() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            rescanRequested = false
            generation += 1
            let current = generation
            let result = await SkillScanner.scan(layout: layout, runner: runner, generation: current)
            guard current == generation else { continue }
            snapshot = result
            prompts.instructions = result.prompts
            prompts.contentGeneration += 1
            if let selection = prompts.selection, prompts.part(id: selection) == nil { prompts.selection = nil }
            if let selection, snapshot.entry(id: selection) == nil { self.selection = nil }
            if let request = deleteRequest {
                deleteRequest = snapshot.entry(id: request.entry.id).map {
                    DeleteRequest(entry: $0, result: DeletePlanner.plan(for: $0, in: snapshot, layout: layout))
                }
            }
            if let request = pushRequest {
                pushRequest = snapshot.entry(id: request.entry.id).map {
                    PushRequest(entry: $0, result: PushPlanner.plan(for: $0, in: snapshot, layout: layout))
                }
            }
        } while rescanRequested
    }

    func requestDelete(_ entry: SkillEntry) {
        deleteRequest = DeleteRequest(entry: entry, result: DeletePlanner.plan(for: entry, in: snapshot, layout: layout))
    }

    func requestPush(_ entry: SkillEntry) {
        pushRequest = PushRequest(entry: entry, result: PushPlanner.plan(for: entry, in: snapshot, layout: layout))
    }

    func perform(_ option: DeleteOption) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await mutator.perform(option)
            deleteRequest = nil
            message = "\(option.title): done."
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func push(_ steps: [PushStep]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let created = try await mutator.perform(steps)
            pushRequest = nil
            message = "Created \(created) link\(created == 1 ? "" : "s")."
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func reveal(_ entry: SkillEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.entryPath)])
    }

    func openSkillFile(_ entry: SkillEntry) {
        guard let resolved = entry.resolvedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: resolved + "/SKILL.md"))
    }
}
