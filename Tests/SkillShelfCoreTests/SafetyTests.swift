import Foundation
import Testing
@testable import SkillShelfCore

@Suite struct SafetyTests {
    @Test func folderReachedThroughSymlinkedSkillsRootIsNotDeletable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill("Developer/source/skills/lambda")
        try FileManager.default.removeItem(atPath: fixture.layout.path(".claude"))
        try FileManager.default.createDirectory(atPath: fixture.layout.path(".claude"), withIntermediateDirectories: true)
        try fixture.link(".claude/skills", to: "../Developer/source/skills")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".claude/skills/lambda"))

        guard case .blocked = DeletePlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("source folder behind a linked root must not be deletable"); return
        }
    }

    @Test func swappedFolderFailsVerification() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/mu")
        let expectation = PathExpectation.folder(fixture.layout.path(".codex/skills/mu"))
        try FileManager.default.removeItem(atPath: fixture.layout.path(".codex/skills/mu"))
        try fixture.skill(".codex/skills/mu")

        #expect(throws: MutationError.self) { try Mutator.verify(expectation) }
    }

    @Test func linkInsideBuiltInRootIsBlocked() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/nu")
        try fixture.link(".grok/bundled/skills/nu", to: "../../../.codex/skills/nu")
        let snapshot = fixture.snapshot()
        let bundledLink = try #require(fixture.entry(snapshot, ".grok/bundled/skills/nu"))
        let real = try #require(fixture.entry(snapshot, ".codex/skills/nu"))

        guard case .blocked = DeletePlanner.plan(for: bundledLink, in: snapshot, layout: fixture.layout) else {
            Issue.record("link in a built-in root must be blocked"); return
        }
        guard case .options(let options) = DeletePlanner.plan(for: real, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected options"); return
        }
        #expect(options.first?.affectedPaths == [real.entryPath])
    }

    @Test func pushResolvesMissingRootUnderLinkedAncestorAndAliasedRoots() throws {
        let fixture = try Fixture(installed: [.claude, .codex, .cursor])
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/xi")
        try FileManager.default.removeItem(atPath: fixture.layout.path(".cursor"))
        try FileManager.default.createDirectory(atPath: fixture.layout.path("Elsewhere/cursor"), withIntermediateDirectories: true)
        try fixture.link(".cursor", to: "Elsewhere/cursor")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/xi"))

        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected steps"); return
        }
        let cursor = try #require(steps.first { $0.harness == .cursor })
        #expect(cursor.outcome == .link(path: fixture.layout.cursorSkills + "/xi", destination: "../../../.codex/skills/xi"))

        _ = try Mutator.preflightAndLink(steps)
        #expect(Paths.canonical(fixture.layout.cursorSkills + "/xi") == entry.resolvedPath)
    }

    @Test func pushTreatsAliasedRootAsAlreadyLinked() throws {
        let fixture = try Fixture(installed: [.claude, .codex, .cursor])
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/omicron")
        try FileManager.default.createDirectory(atPath: fixture.layout.claudeSkills, withIntermediateDirectories: true)
        try fixture.link(".cursor/skills", to: "../.claude/skills")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/omicron"))

        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected steps"); return
        }
        let links = steps.filter { if case .link = $0.outcome { true } else { false } }
        #expect(links.map(\.harness) == [.claude])
    }

    @Test func sameNameFolderWithoutSkillFileIsAConflict() throws {
        let fixture = try Fixture(installed: [.claude, .codex])
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/pi")
        try fixture.write(".claude/skills/pi/notes.txt", "not a skill")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/pi"))

        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout),
              case .conflict = steps.first(where: { $0.harness == .claude })?.outcome
        else { Issue.record("expected conflict for claude"); return }
    }

    @Test func pushPreflightRefusesWhenAnyDestinationAppeared() throws {
        let fixture = try Fixture(installed: [.claude, .codex, .cursor])
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/rho")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/rho"))
        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected steps"); return
        }
        try fixture.write(".cursor/skills/rho/SKILL.md", "---\nname: rho\n---\n")

        #expect(throws: MutationError.self) { try Mutator.preflightAndLink(steps) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.layout.claudeSkills + "/rho")) == nil)
    }
}

@Suite struct RunnerTests {
    @Test func timeoutKillsProcessThatIgnoresTerminate() async throws {
        let runner = LoginShellRunner(timeout: .milliseconds(300))
        let start = ContinuousClock.now

        await #expect(throws: CommandError.self) {
            _ = try await runner.run("zsh", ["-c", "trap '' TERM; sleep 20"])
        }
        #expect(ContinuousClock.now - start < .seconds(8))
    }
}
