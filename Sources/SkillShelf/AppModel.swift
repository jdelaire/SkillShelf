import AppKit
import Observation
import SkillShelfCore

enum SidebarItem: Hashable {
    case all
    case harness(HarnessID)
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
    private let runner: LoginShellRunner
    private let mutator: Mutator

    var snapshot = Snapshot.empty
    var sidebar: SidebarItem? = .all
    var selection: String?
    var search = ""
    var isScanning = false
    var isWorking = false
    var deleteRequest: DeleteRequest?
    var pushRequest: PushRequest?
    var message: String?
    var errorMessage: String?
    private var generation = 0

    init(layout: Layout = Layout()) {
        self.layout = layout
        runner = LoginShellRunner(home: layout.home)
        mutator = Mutator(layout: layout, runner: runner)
    }

    var rows: [HarnessRow] {
        let base: [HarnessRow]
        switch sidebar {
        case .harness(let harness): base = snapshot.rows(for: harness)
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
        generation += 1
        let current = generation
        isScanning = true
        let result = await SkillScanner.scan(layout: layout, runner: runner, generation: current)
        guard current == generation else { return }
        snapshot = result
        isScanning = false
        if let selection, snapshot.entry(id: selection) == nil { self.selection = nil }
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
