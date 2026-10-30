import Foundation
import Testing
@testable import SkillShelfCore

@Suite struct InstructionReaderTests {
    @Test func claudeImportsRecurseFourHopsAndStopAtCycles() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "See @a.md")
        try f.write(".claude/a.md", "@b.md"); try f.write(".claude/b.md", "@c.md")
        try f.write(".claude/c.md", "@d.md"); try f.write(".claude/d.md", "@e.md @CLAUDE.md")
        try f.write(".claude/e.md", "too deep")
        let paths = InstructionReader.parts(layout: f.layout, harness: .claude).compactMap(\.filePath)
        #expect(Array(paths.prefix(5)) == ["CLAUDE.md", "a.md", "b.md", "c.md", "d.md"].map { f.layout.path(".claude/\($0)") })
        #expect(!paths.contains(f.layout.path(".claude/e.md")))
        #expect(paths.filter { $0 == f.layout.path(".claude/CLAUDE.md") }.count == 1)
    }

    @Test func claudeMissingImportIsListedAsMissing() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "@gone.md")
        let gone = InstructionReader.parts(layout: f.layout, harness: .claude).first { $0.filePath == f.layout.path(".claude/gone.md") }
        #expect(gone?.status == .missing)
        #expect(gone?.notes == ["Imported by ~/.claude/CLAUDE.md"])
    }

    @Test func claudeImportsResolveRelativeAndHomePathsOutsideFences() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", """
        @nested/one.md @~/home.md @\(f.home)/absolute.md
        email@ignored.md `@inline.md` word@ignored.md
        ```markdown
        @fenced.md
        ```
          ~~~~
        @tilde-fenced.md
          ~~~~
        """)
        try f.write(".claude/nested/one.md", "@../shared.md")
        try f.write(".claude/shared.md", "x")
        try f.write("home.md", "x")
        try f.write("absolute.md", "x")
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude)
        #expect(parts.compactMap(\.filePath) == [
            f.layout.path(".claude/CLAUDE.md"), f.layout.path(".claude/nested/one.md"),
            f.layout.path(".claude/shared.md"), f.layout.path("home.md"), f.layout.path("absolute.md"),
        ])
        #expect(parts[2].notes == ["Imported by ~/.claude/nested/one.md"])
    }

    @Test func claudeCanonicalImportCycleStopsAtSymlink() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "@alias.md @shared.md")
        try f.link(".claude/alias.md", to: "CLAUDE.md")
        try f.write(".claude/shared.md", "x")
        #expect(InstructionReader.parts(layout: f.layout, harness: .claude).compactMap(\.filePath) == [
            f.layout.path(".claude/CLAUDE.md"), f.layout.path(".claude/shared.md"),
        ])
    }

    @Test func claudeSkipsImportsAboveOneMegabyte() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "@too-deep.md\n" + String(repeating: "x", count: 1_048_576))
        let files = InstructionFiles()
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude, files: files)
        #expect(parts.compactMap(\.filePath) == [f.layout.path(".claude/CLAUDE.md")])
        #expect(parts[0].status == .present)
        #expect(files.reads == 0)
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

    @Test func claudeRulesRecurseInOrderBeforeCaseInsensitiveUserStyle() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/rules/z.md", "x")
        try f.write(".claude/rules/a/first.md", "x")
        try f.write(".claude/rules/a/ignored.txt", "x")
        try f.write(".claude/output-styles/Custom.md", "x")
        try f.write(".claude/settings.json", #"{"outputStyle":"custom"}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude)
        #expect(parts.compactMap(\.filePath) == [
            f.layout.path(".claude/CLAUDE.md"), f.layout.path(".claude/rules/a/first.md"),
            f.layout.path(".claude/rules/z.md"), f.layout.path(".claude/output-styles/Custom.md"),
        ])
        #expect(parts.last?.status == .present)
        try f.write(".claude/settings.json", #"{"outputStyle":"default"}"#)
        #expect(InstructionReader.parts(layout: f.layout, harness: .claude).count == 3)
    }

    @Test func codexOverrideWinsAndConfigKeysBecomeParts() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".codex/AGENTS.md", "base"); try f.write(".codex/AGENTS.override.md", "override")
        try f.write(".codex/config.toml", "developer_instructions = \"dev\"\nmodel_instructions_file = \"~/m.md\"")
        let parts = InstructionReader.parts(layout: f.layout, harness: .codex, environment: [:])
        #expect(parts.map(\.title).contains("~/.codex/AGENTS.override.md"))
        #expect(!parts.map(\.title).contains("~/.codex/AGENTS.md"))
        #expect(parts.contains { $0.title == "config.toml › developer_instructions" })
        #expect(parts.first { $0.title == "~/m.md" }?.notes.contains("Replaces the base prompt") == true)
    }

    @Test func codexHomeAndEmptyOverridePreserveInstructionOrder() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("custom/AGENTS.override.md", "")
        try f.write("custom/AGENTS.md", "base")
        try f.write("custom/config.toml", """
        developer_instructions = "dev"
        model_instructions_file = "model.md"
        instructions = "first"
        """)
        try f.write("custom/model.md", "model")
        let parts = InstructionReader.parts(layout: f.layout, harness: .codex, environment: ["CODEX_HOME": f.layout.path("custom")])
        #expect(parts.map(\.title) == [
            "~/custom/AGENTS.md", "config.toml › instructions", "config.toml › developer_instructions", "~/custom/model.md",
        ])
        #expect(parts[1].source == .file(path: f.layout.path("custom/config.toml"), key: "instructions"))
        #expect(parts.allSatisfy { $0.status == .present })
    }

    @Test func malformedCodexConfigStillListsFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".codex/AGENTS.md", "base"); try f.write(".codex/config.toml", "[[[ nope")
        #expect(InstructionReader.parts(layout: f.layout, harness: .codex, environment: [:]).contains { $0.title == "~/.codex/AGENTS.md" })
    }

    @Test func sharedImportIsReadOncePerScan() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "@shared.md"); try f.write(".claude/shared.md", "x")
        try f.write(".codex/AGENTS.md", "x"); try f.link(".gemini/GEMINI.md", to: "../.claude/shared.md")
        let files = InstructionFiles()
        for harness in [HarnessID.claude, .antigravity] {
            _ = InstructionReader.parts(layout: f.layout, harness: harness, files: files)
        }
        #expect(files.reads == 2)
    }

    @Test func instructionFilesCacheCanonicalContentAndMissingReads() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("shared.md", "original")
        try f.link("alias.md", to: "shared.md")
        let files = InstructionFiles()
        #expect(files.text(f.layout.path("shared.md")) == "original")
        try f.write("shared.md", "changed")
        #expect(files.text(f.layout.path("alias.md")) == "original")
        #expect(files.head(f.layout.path("shared.md"), bytes: 4) == "orig")
        #expect(files.reads == 1)
        #expect(files.text(f.layout.path("missing.md")) == nil)
        try f.write("missing.md", "created after scan")
        #expect(files.text(f.layout.path("missing.md")) == nil)
        #expect(files.reads == 1)
    }

    @Test func instructionFilesCanCompleteCachedPrefixWithoutRereading() throws {
        let f = try Fixture(); defer { f.remove() }
        let content = String(repeating: "x", count: 4_096) + "tail"
        try f.write("large.md", content)
        try f.link("alias.md", to: "large.md")
        let files = InstructionFiles()
        #expect(files.head(f.layout.path("large.md")) == String(repeating: "x", count: 4_096))
        #expect(files.text(f.layout.path("alias.md")) == content)
        #expect(files.reads == 1)
    }

    @Test func ruleFrontmatterReadsOnlyFirstFourKilobytes() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/rules/late.md", "---\n" + String(repeating: "x", count: 4_096) + "\npaths: **/*.swift\n---\n")
        let files = InstructionFiles()
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude, files: files)
        #expect(parts.last?.notes.isEmpty == true)
        #expect(files.reads == 1)
    }

    @Test func largeRuleTreeStopsAt500() throws {
        let f = try Fixture(); defer { f.remove() }
        for i in 0..<510 { try f.write(".claude/rules/r\(i).md", "x") }
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude)
        #expect(parts.filter { $0.filePath?.contains("/rules/") == true }.count == 500)
        #expect(parts.contains { $0.notes.contains("Stopped after 500 rule files") })
    }

    @Test func ruleTreeSkipsDirectorySymlinkCyclesAndMarksFileDuplicates() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "x")
        try f.link(".claude/rules/loop", to: ".")
        try f.link(".claude/rules/duplicate.md", to: "../CLAUDE.md")
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude)
        #expect(parts.count == 2)
        #expect(parts[0].notes == ["Same file as ~/.claude/rules/duplicate.md, loaded twice"])
        #expect(parts[1].notes == ["Same file as ~/.claude/CLAUDE.md, loaded twice"])
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
        let muse = InstructionReader.parts(layout: f.layout, harness: .muse, environment: [:])
        #expect(muse.contains { $0.title == "settings.json › run.developer_prompt" })
        #expect(!muse.contains { $0.filePath == f.layout.path(".claude/CLAUDE.md") })
    }

    @Test func antigravityKeepsSourceOrderAndRuleTreesAreShallow() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".gemini/config/rules/z.md", "---\ntrigger: always_on\n---\nx")
        try f.write(".gemini/config/rules/a.md", "---\ntrigger: manual\n---\nx")
        try f.write(".gemini/config/rules/nested/ignored.md", "x")
        try f.write(".gemini/antigravity-cli/rules/last.md", "---\ntrigger: glob\n---\nx")
        let parts = InstructionReader.parts(layout: f.layout, harness: .antigravity)
        #expect(parts.map(\.title) == [
            "~/.gemini/AGENTS.md", "~/.gemini/GEMINI.md", "~/.gemini/config/AGENTS.md", "~/.gemini/config/GEMINI.md",
            "~/.gemini/config/rules/a.md", "~/.gemini/config/rules/z.md", "~/.gemini/antigravity-cli/rules/last.md",
        ])
        #expect(parts.prefix(4).allSatisfy { $0.status == .missing })
        #expect(parts[5].notes.isEmpty)
    }

    @Test func museConfigKeysPrecedeForeignFilesAndCodexHomeApplies() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/muse/settings.json", #"{"run":{"system_prompt":"system","developer_prompt":"developer"}}"#)
        try f.write("custom/AGENTS.md", "x")
        try f.link(".claude/CLAUDE.md", to: "../custom/AGENTS.md")
        let parts = InstructionReader.parts(layout: f.layout, harness: .muse, environment: ["CODEX_HOME": f.layout.path("custom")])
        #expect(parts.map(\.title) == [
            "settings.json › run.system_prompt", "settings.json › run.developer_prompt", "~/.claude/CLAUDE.md", "~/custom/AGENTS.md",
        ])
        #expect(parts[0].source == .file(path: f.layout.path(".config/muse/settings.json"), key: "run.system_prompt"))
        #expect(parts[2].notes == ["Same file as ~/custom/AGENTS.md, loaded twice"])
        #expect(parts[3].notes == ["Same file as ~/.claude/CLAUDE.md, loaded twice"])
    }

    @Test func missingMuseSettingsStillListsForeignSources() throws {
        let f = try Fixture(); defer { f.remove() }
        let parts = InstructionReader.parts(layout: f.layout, harness: .muse, environment: [:])
        #expect(parts.map(\.title) == ["~/.claude/CLAUDE.md", "~/.codex/AGENTS.md"])
        #expect(parts.allSatisfy { $0.status == .missing })
    }

    @Test func configKeyPartsSharingCanonicalTargetAreMarked() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".codex/config.toml", "instructions = \"one\"\ndeveloper_instructions = \"two\"")
        let parts = InstructionReader.parts(layout: f.layout, harness: .codex, environment: [:])
        #expect(parts.dropFirst().count == 2)
        #expect(parts[1].notes == ["Same file as config.toml › developer_instructions, loaded twice"])
        #expect(parts[2].notes == ["Same file as config.toml › instructions, loaded twice"])
    }

    @Test func promptIDsUseSourceIdentityAndIgnoreTitleChanges() {
        let file = PromptPart(harness: .codex, layer: .instructions, title: "first", source: .file(path: "/tmp/config.toml", key: "instructions"), status: .present)
        let renamed = PromptPart(harness: .codex, layer: .instructions, title: "second", source: file.source, status: .missing)
        let remote = PromptPart(harness: .codex, layer: .base, title: "remote", source: .remote(url: URL(string: "https://example.com/prompt")!, cache: "/tmp/cache"), status: .present)
        let capture = PromptPart(harness: .claude, layer: .capture, title: "capture", source: .capture(path: "/tmp/capture.json"), status: .present)
        let unavailable = PromptPart(harness: .cursor, layer: .instructions, title: "User rules", source: .none, status: .unavailable("Managed remotely"))
        #expect(file.id == "codex/instructions//tmp/config.toml#instructions")
        #expect(file.id == renamed.id)
        #expect(remote.id == "codex/base/https://example.com/prompt")
        #expect(capture.id == "claude/capture//tmp/capture.json")
        #expect(unavailable.id == "cursor/instructions/User rules")
        #expect(remote.filePath == nil)
    }
}
