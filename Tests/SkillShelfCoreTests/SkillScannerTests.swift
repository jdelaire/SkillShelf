import Darwin
import Foundation
import Testing
@testable import SkillShelfCore

@Suite struct SkillScannerTests {
    @Test func snapshotIncludesCustomHomePromptsWithoutChangingSkillRoots() async {
        await #expect(processExitsWith: .success) {
            let f = try Fixture(installed: [.claude]); defer { f.remove() }
            try f.write("custom/codex/AGENTS.md", "codex-fixture")
            try f.write("custom/grok/AGENTS.md", "grok-fixture")
            try f.write("custom/grok/config.toml", "[compat.claude]\nagents = false\nrules = false\n[compat.cursor]\nagents = false\nrules = false")
            try f.skill("custom/codex/skills/custom-codex")
            try f.skill("custom/grok/skills/custom-grok")
            try f.skill(".claude/skills/existing")
            try #require(!FileManager.default.fileExists(atPath: f.layout.path(".codex")))
            try #require(!FileManager.default.fileExists(atPath: f.layout.path(".grok")))

            for prefix in [f.home + "/", "~/", ""] {
                try #require(setenv("CODEX_HOME", prefix + "custom/codex", 1) == 0)
                try #require(setenv("GROK_HOME", prefix + "custom/grok", 1) == 0)
                let snapshot = f.snapshot()
                try #require(Set(snapshot.prompts.keys) == [.claude, .codex, .grok])
                try #require(snapshot.promptHarnesses == [.claude, .codex, .grok])
                try #require(snapshot.prompts[.codex]?.contains {
                    $0.source == .file(path: f.layout.path("custom/codex/AGENTS.md"), key: nil) && $0.status == .present
                } == true)
                try #require(snapshot.prompts[.grok]?.contains {
                    $0.source == .file(path: f.layout.path("custom/grok/AGENTS.md"), key: nil) && $0.status == .present
                } == true)
                try #require(snapshot.harnesses == [.claude])
                try #require(snapshot.entries.map(\.folderName) == ["existing"])
            }

            try f.skill(".codex/skills/default-codex")
            try f.skill(".grok/skills/default-grok")
            let snapshot = f.snapshot()
            try #require(snapshot.harnesses == [.claude, .codex, .grok])
            try #require(Set(snapshot.entries.map(\.folderName)) == ["existing", "default-codex", "default-grok"])
            try #require(snapshot.harnessRoots[.codex]?.first?.root.path == f.layout.codexSkills)
            try #require(snapshot.harnessRoots[.grok]?.first?.root.path == f.layout.grokSkills)
        }
    }

    @Test func snapshotCarriesInstructionParts() throws {
        let fixture = try Fixture(installed: [.codex])
        defer { fixture.remove() }
        try fixture.write(".codex/AGENTS.md", "x")

        let snapshot = fixture.snapshot()

        #expect(snapshot.prompts[.codex]?.contains {
            $0.title == "~/.codex/AGENTS.md" && $0.status == .present
        } == true)
        #expect(Set(snapshot.prompts.keys) == Set(snapshot.harnesses))
    }

    @Test func snapshotRebuildsInstructionsAfterFileRemoval() throws {
        let fixture = try Fixture(installed: [.claude])
        defer { fixture.remove() }
        try fixture.write(".claude/CLAUDE.md", "@extra.md")
        try fixture.write(".claude/extra.md", "Extra")
        let first = fixture.snapshot()
        try FileManager.default.removeItem(atPath: fixture.layout.path(".claude/extra.md"))

        let second = fixture.snapshot()

        #expect(first.prompts[.claude]?.first { $0.title == "~/.claude/extra.md" }?.status == .present)
        #expect(second.prompts[.claude]?.first { $0.title == "~/.claude/extra.md" }?.status == .missing)
        #expect(Snapshot.empty.prompts.isEmpty)
    }

    @Test func classifiesFoldersLinksAndBrokenLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/alpha")
        try fixture.link(".claude/skills/alpha", to: "../../.codex/skills/alpha")
        try fixture.link(".claude/skills/ghost", to: "../../nowhere/ghost")
        try fixture.write(".claude/skills/notes/README.md", "no skill here")

        let snapshot = fixture.snapshot()

        let real = try #require(fixture.entry(snapshot, ".codex/skills/alpha"))
        #expect(!real.isSymlink)
        #expect(real.name == "alpha")
        #expect(real.description == "About alpha")
        let link = try #require(fixture.entry(snapshot, ".claude/skills/alpha"))
        #expect(link.isSymlink)
        #expect(link.resolvedPath == real.entryPath)
        let ghost = try #require(fixture.entry(snapshot, ".claude/skills/ghost"))
        #expect(ghost.isBroken)
        #expect(fixture.entry(snapshot, ".claude/skills/notes") == nil)
    }

    @Test func linkIntoBuiltInFolderIsProtected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".cursor/skills-cursor/shell")
        try fixture.link(".claude/skills/shell", to: "../../.cursor/skills-cursor/shell")

        let link = try #require(fixture.entry(fixture.snapshot(), ".claude/skills/shell"))

        #expect(link.protection == .builtIn)
    }

    @Test func syncedClaudeSkillsAreManagedNotUser() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".claude/skills/synced/org_user/pdf")

        let snapshot = fixture.snapshot()

        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.protection == .managed)
    }

    @Test func harnessViewsFlagDuplicatesAndThirdPartyRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/beta")
        try fixture.skill(".agents/skills/beta")
        try fixture.skill(".claude/skills/gamma")

        let snapshot = fixture.snapshot()

        let codex = snapshot.rows(for: .codex)
        #expect(codex.count == 2)
        #expect(codex.allSatisfy { $0.duplicate })
        let cursorGamma = try #require(snapshot.rows(for: .cursor).first { $0.entry.folderName == "gamma" })
        #expect(cursorGamma.thirdParty)
        #expect(snapshot.rows(for: .opencode).contains { $0.entry.folderName == "gamma" && !$0.thirdParty })
    }

    @Test func grokCompatSwitchesDropRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.skill(".claude/skills/delta")
        let compat = PluginReaders.grokCompat(config: "[compat.claude]\nskills = false\n")

        let snapshot = fixture.snapshot(.init(grokCompat: compat))

        #expect(!snapshot.rows(for: .grok).contains { $0.entry.folderName == "delta" })
    }
}

@Suite struct DetectionTests {
    @Test func onlyInstalledHarnessesAppearAndGetPushed() throws {
        let fixture = try Fixture(installed: [.claude, .codex])
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/iota")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".codex/skills/iota"))

        #expect(snapshot.harnesses == [.claude, .codex])
        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected steps"); return
        }
        #expect(steps.map(\.harness) == [.claude, .codex])
    }

    @Test func antigravityRunningThroughT3IsDetectedAndPushedToItsConfigFolder() throws {
        let fixture = try Fixture(installed: [.claude])
        defer { fixture.remove() }
        try FileManager.default.createDirectory(atPath: fixture.layout.path(".t3/tools/antigravity-acp"), withIntermediateDirectories: true)
        try fixture.skill(".claude/skills/kappa")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".claude/skills/kappa"))

        #expect(snapshot.harnesses == [.claude, .antigravity])
        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected steps"); return
        }
        #expect(steps.last?.outcome == .link(path: fixture.layout.path(".gemini/config/skills/kappa"), destination: "../../../.claude/skills/kappa"))
    }
}

@Suite struct FrontmatterTests {
    @Test func bodyDropsFrontmatterAndKeepsMarkdown() {
        let text = "---\nname: phi\ndescription: >\n  folded\n---\n\n# Phi\n\n- one\n---\nafter rule\n"
        #expect(Frontmatter.body(text) == "# Phi\n\n- one\n---\nafter rule")
        #expect(Frontmatter.body("# No frontmatter") == "# No frontmatter")
    }
}

@Suite struct MuseTests {
    @Test func museSeesSharedFoldersAndKeepsBundledSkillsReadOnly() throws {
        let fixture = try Fixture(installed: [.codex, .muse])
        defer { fixture.remove() }
        try fixture.skill(".codex/skills/sigma")
        try fixture.skill(".local/share/muse/skills/bundled/muse-core/skills/tau")
        let snapshot = fixture.snapshot()

        let rows = snapshot.rows(for: .muse)
        #expect(rows.contains { $0.entry.folderName == "sigma" })
        let bundled = try #require(rows.first { $0.entry.folderName == "tau" }?.entry)
        #expect(!bundled.isDeletable)
    }

    @Test func museViewFollowsMuseOwnSkillList() throws {
        let fixture = try Fixture(installed: [.claude, .muse])
        defer { fixture.remove() }
        try fixture.skill(".claude/skills/chi")
        try fixture.skill(".local/share/muse/skills/bundled/muse-core/skills/psi")
        try fixture.skill(".local/share/muse/skills/bundled/muse-core/skills/rejected")
        let list = """
        {"skills": [
          {"path": "$HOME/.claude/skills/chi/SKILL.md"},
          {"path": "bundled://muse-core/skills/psi/SKILL.md"},
          {"path": "plugin://threejs/skills/threejs/SKILL.md"}
        ]}
        """
        var inputs = SkillScanner.Inputs()
        inputs.visible[.muse] = try #require(PluginReaders.museEntryPaths(listJSON: Data(list.utf8), layout: fixture.layout))
        let snapshot = fixture.snapshot(inputs)

        #expect(Set(snapshot.rows(for: .muse).map(\.entry.folderName)) == ["chi", "psi"])
        #expect(snapshot.rows(for: .claude).map(\.entry.folderName) == ["chi"])
    }

    @Test func pushLinksIntoMuseConfigWhenNoSharedFolderHasIt() throws {
        let fixture = try Fixture(installed: [.muse])
        defer { fixture.remove() }
        try fixture.skill("Developer/stack/skills/upsilon")
        try fixture.link(".config/muse/skills/upsilon-alias", to: "../../../Developer/stack/skills/upsilon")
        let snapshot = fixture.snapshot()
        let entry = try #require(fixture.entry(snapshot, ".config/muse/skills/upsilon-alias"))

        guard case .steps(let steps) = PushPlanner.plan(for: entry, in: snapshot, layout: fixture.layout) else {
            Issue.record("expected steps"); return
        }
        #expect(steps.map(\.outcome) == [.link(path: fixture.layout.museSkills + "/upsilon", destination: "../../../Developer/stack/skills/upsilon")])
    }
}

@Suite struct PluginReaderTests {
    @Test func claudeReadsOnlyEnabledUserScopePlugins() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installPath = fixture.layout.path(".claude/plugins/cache/market/tools/1.0")
        try fixture.write(".claude/plugins/cache/market/tools/1.0/.claude-plugin/plugin.json", #"{"skills": "./extras/"}"#)
        let installed = """
        {"plugins": {
          "tools@market": [{"scope": "user", "installPath": "\(installPath)"}],
          "off@market": [{"scope": "user", "installPath": "/x"}],
          "proj@market": [{"scope": "project", "installPath": "/y"}]
        }}
        """
        let settings = #"{"enabledPlugins": {"tools@market": true, "off@market": false, "proj@market": true}}"#

        let roots = PluginReaders.claudeRoots(installed: Data(installed.utf8), settings: Data(settings.utf8))

        #expect(roots.map(\.path) == [installPath + "/extras"])
        #expect(roots.first?.plugin == PluginRef(owner: .claude, id: "tools@market", removable: true))
    }

    @Test func codexUsesCachedVersionAndMarksBundledReadOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(".codex/plugins/cache/openai-bundled/chrome/2.0/.codex-plugin/plugin.json", "{}")
        try fixture.write(".codex/plugins/cache/remote/kit/1.1/.codex-plugin/plugin.json", "{}")
        try fixture.write(".codex/plugins/cache/remote/pets/1.0/.codex-plugin/plugin.json", "{}")
        let list = """
        {"installed": [
          {"pluginId": "chrome@openai-bundled", "name": "chrome", "marketplaceName": "openai-bundled", "version": "2.0", "installed": true, "enabled": true},
          {"pluginId": "kit@remote", "name": "kit", "marketplaceName": "remote", "version": "1.1", "installed": true, "enabled": true},
          {"pluginId": "off@remote", "name": "off", "marketplaceName": "remote", "version": "1.0", "installed": true, "enabled": false},
          {"pluginId": "pets@remote", "name": "pets", "marketplaceName": "remote", "version": "1.0", "installed": true, "enabled": true, "installPolicy": "INSTALLED_BY_DEFAULT"}
        ]}
        """

        let roots = PluginReaders.codexRoots(listJSON: Data(list.utf8), cache: fixture.layout.codexPluginCache)

        #expect(roots.count == 3)
        #expect(roots.first { $0.plugin?.id == "pets@remote" }?.plugin?.removable == false)
        #expect(roots.first { $0.plugin?.id == "chrome@openai-bundled" }?.plugin?.removable == false)
        #expect(roots.first { $0.plugin?.id == "kit@remote" }?.path == fixture.layout.codexPluginCache + "/remote/kit/1.1/skills")
    }
}
