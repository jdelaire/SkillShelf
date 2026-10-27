import Foundation
import Testing
@testable import SkillShelfCore

@Suite struct DeletePlannerTests {
    func options(_ result: DeletePlanner.Result) -> [DeleteOption] {
        if case .options(let options) = result { return options }
        return []
    }

    @Test func externalSourceIsNeverTrashed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill("Developer/stack/skills/council")
        try fixture.link(".claude/skills/council", to: "../../Developer/stack/skills/council")
        try fixture.link(".codex/skills/council", to: "../../Developer/stack/skills/council")
        let snapshot = fixture.snapshot()
        let link = try #require(fixture.entry(snapshot, ".claude/skills/council"))

        let planned = options(DeletePlanner.plan(for: link, in: snapshot, layout: fixture.layout))

        #expect(planned.map(\.title) == ["Remove this link", "Remove all links"])
        let source = fixture.layout.path("Developer/stack/skills/council")
        #expect(planned.allSatisfy { !$0.affectedPaths.contains(source) })
        #expect(planned.last?.affectedPaths.count == 2)
    }

    @Test func folderInUserRootTakesItsLinksAndLockEntry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".agents/skills/epsilon")
        try fixture.link(".claude/skills/epsilon", to: "../../.agents/skills/epsilon")
        let snapshot = fixture.snapshot()
        let link = try #require(fixture.entry(snapshot, ".claude/skills/epsilon"))

        let everywhere = try #require(options(DeletePlanner.plan(for: link, in: snapshot, layout: fixture.layout))
            .first { $0.title == "Delete everywhere" })

        guard case .trash(let items, let lockKey) = everywhere.action else { Issue.record("expected trash"); return }
        #expect(Set(items.map(\.path)) == [fixture.layout.path(".agents/skills/epsilon"), fixture.layout.path(".claude/skills/epsilon")])
        #expect(lockKey == "epsilon")
    }

    @Test func linkToProtectedTargetOnlyRemovesLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".grok/bundled/skills/zeta")
        try fixture.link(".grok/skills/zeta", to: "../bundled/skills/zeta")
        let snapshot = fixture.snapshot()

        let link = try #require(fixture.entry(snapshot, ".grok/skills/zeta"))
        let bundled = try #require(fixture.entry(snapshot, ".grok/bundled/skills/zeta"))

        #expect(options(DeletePlanner.plan(for: link, in: snapshot, layout: fixture.layout)).map(\.title) == ["Remove this link"])
        guard case .blocked = DeletePlanner.plan(for: bundled, in: snapshot, layout: fixture.layout) else {
            Issue.record("built-in skill must be blocked"); return
        }
    }
}

@Suite struct PushPlannerTests {
    func steps(_ result: PushPlanner.Result) -> [PushStep] {
        if case .steps(let steps) = result { return steps }
        return []
    }

    @Test func linksOnlyWhereNeededAndReusesSharedRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill("Developer/stack/skills/council")
        try fixture.link(".codex/skills/council", to: "../../Developer/stack/skills/council")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/council"))

        let planned = steps(PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout))
        let outcomes = Dictionary(uniqueKeysWithValues: planned.map { ($0.harness, $0.outcome) })

        #expect(outcomes[.claude] == .link(path: fixture.layout.claudeSkills + "/council", destination: "../../Developer/stack/skills/council"))
        guard case .present = outcomes[.codex] else { Issue.record("codex already has it"); return }
        guard case .link = outcomes[.cursor] else { Issue.record("cursor ignores third-party roots for push"); return }
        guard case .present = outcomes[.opencode] else { Issue.record("opencode reads the new claude link"); return }
        guard case .present = outcomes[.grok] else { Issue.record("grok reads the new claude link"); return }
    }

    @Test func differentSkillWithSameNameIsAConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/eta")
        try fixture.skill(".claude/skills/eta")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/eta"))

        let planned = steps(PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout))

        guard case .conflict = planned.first(where: { $0.harness == .claude })?.outcome else {
            Issue.record("claude has a different eta"); return
        }
    }

    @Test func protectedSkillCannotBePushed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/.system/theta")
        try fixture.link(".agents/skills/theta", to: "../../.codex/skills/.system/theta")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".agents/skills/theta"))

        guard case .blocked = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("protected target must be blocked"); return
        }
    }
}
