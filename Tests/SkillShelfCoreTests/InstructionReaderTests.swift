import Darwin
import Foundation
import Testing
@testable import SkillShelfCore

@Suite struct InstructionReaderTests {
    @Test func grokLoadsEveryNamedFileOnceAndHonorsGrokHome() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("gh/AGENTS.md", "a"); try f.write("gh/CLAUDE.local.md", "b")
        try f.write("gh/rules/b.md", "x"); try f.write("gh/rules/a.md", "x")
        try f.write(".claude/CLAUDE.md", "c")
        try f.write("gh/config.toml", "[compat.claude]\nrules = false")
        let parts = InstructionReader.parts(layout: f.layout, harness: .grok, environment: ["GROK_HOME": f.layout.path("gh")])
        let present = parts.filter { $0.status == .present }.compactMap(\.filePath)
        #expect(present.contains(f.layout.path("gh/AGENTS.md")) && present.contains(f.layout.path("gh/CLAUDE.local.md")))
        #expect(present.filter { $0.hasPrefix(f.layout.path("gh/rules")) } == ["a.md", "b.md"].map { f.layout.path("gh/rules/\($0)") })
        #expect(present.contains(f.layout.path(".claude/CLAUDE.md")))
    }

    @Test func grokCaseInsensitiveDuplicateCountsOnce() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".grok/CLAUDE.md", "x")
        let present = InstructionReader.parts(layout: f.layout, harness: .grok).filter { $0.status == .present && $0.filePath?.hasPrefix(f.layout.path(".grok/")) == true }
        #expect(present.count == 1)
    }

    @Test func grokCompatAgentsAndRulesSwitchesAreIndependentOfSkills() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".grok/CLAUDE.md", "native")
        try f.write(".claude/AGENTS.md", "claude")
        try f.write(".claude/rules/c.md", "rule")
        try f.write(".cursor/AGENTS.md", "cursor")
        try f.write(".cursor/rules/u.md", "rule")
        try f.write(".grok/config.toml", """
        [compat.claude]
        skills = false
        agents = false
        rules = true
        [compat.cursor]
        skills = false
        agents = true
        rules = false
        """)
        let first = InstructionReader.parts(layout: f.layout, harness: .grok).filter { $0.status == .present }.compactMap(\.filePath)
        #expect(first == [".grok/CLAUDE.md", ".cursor/AGENTS.md", ".claude/rules/c.md"].map(f.layout.path))
        try f.write(".grok/config.toml", """
        [compat.claude]
        agents = true
        rules = false
        [compat.cursor]
        agents = false
        rules = true
        """)
        let second = InstructionReader.parts(layout: f.layout, harness: .grok).filter { $0.status == .present }.compactMap(\.filePath)
        #expect(second == [".grok/CLAUDE.md", ".claude/AGENTS.md", ".cursor/rules/u.md"].map(f.layout.path))
    }

    @Test func grokDeduplicatesNamedFilesByDeviceAndInode() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".grok/AGENT.md", "x")
        try FileManager.default.linkItem(atPath: f.layout.path(".grok/AGENT.md"), toPath: f.layout.path(".grok/CLAUDE.local.md"))
        try f.link(".claude/AGENTS.md", to: "../.grok/AGENT.md")
        let present = InstructionReader.parts(layout: f.layout, harness: .grok).filter { $0.status == .present }
        #expect(present.count == 1)
        #expect(present.first?.filePath == f.layout.path(".grok/CLAUDE.local.md"))
        #expect(present.first?.notes.isEmpty == true)
    }

    @Test func grokExtraRulesAreShallowSortedAndIgnoreRelativeDirectories() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".grok/rules/z.md", "native")
        try f.write(".claude/rules/c.md", "claude")
        try f.write(".cursor/rules/u.md", "cursor")
        try f.write("team/b.md", "b")
        try f.write("team/a.md", "a")
        try f.write("team/deep/ignored.md", "x")
        try f.write("relative/ignored.md", "x")
        try f.write("absolute/last.md", "last")
        try f.write(".grok/config.toml", """
        [paths]
        extra_rule_dirs = ["~/team", "relative", "\(f.layout.path("absolute"))", "~/gone"]
        """)
        let files = InstructionFiles()
        let parts = InstructionReader.parts(layout: f.layout, harness: .grok, files: files)
        #expect(parts.filter { $0.status == .present }.compactMap(\.filePath) == [
            ".grok/rules/z.md", ".claude/rules/c.md", ".cursor/rules/u.md", "team/a.md", "team/b.md", "absolute/last.md",
        ].map(f.layout.path))
        #expect(files.reads == 7)
        #expect(parts.contains { $0.status == .missing && $0.filePath == f.layout.path(".grok/AGENTS.md") })
    }

    @Test func opencodeMergesConfigsAndExpandsFileSubstitution() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/config.json", #"{"instructions":["~/old.md"]}"#)
        try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["~/a.md","https://x.dev/r.md"],"agent":{"rev":{"prompt":"{file:./rev.txt}"}},"default_agent":"rev"}"#)
        try f.write(".config/opencode/rev.txt", "review prompt"); try f.write("a.md", "x")
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        #expect(parts.contains { $0.filePath == f.layout.path("a.md") })
        #expect(!parts.contains { $0.filePath == f.layout.path("old.md") })
        #expect(parts.contains { if case .remote = $0.source { true } else { false } })
        let rev = try #require(parts.first { $0.layer == .agentDefinitions && $0.filePath == f.layout.path(".config/opencode/rev.txt") })
        #expect(rev.notes.contains("via {file:} in opencode.jsonc"))
        #expect(rev.notes.contains("Active agent"))
    }

    @Test func opencodeAgentsRecursiveAndNoActiveWithoutDefault() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/agents/team/deep.md", "x"); try f.write(".config/opencode/agent/old.md", "x")
        let agents = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .agentDefinitions }
        #expect(agents.filter { $0.filePath != nil }.count == 2)
        #expect(agents.filter { $0.source == .none }.map(\.status) == [.unavailable("No default_agent set")])
        #expect(agents.contains { $0.title == "OpenCode uses the first enabled primary agent. Capture shows which." })
        #expect(!agents.contains { $0.notes.contains("Active agent") })
    }

    @Test func opencodeFileSubstitutionEscapesContentAndKeepsSiblings() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/multi.txt", "line \"one\"\nC:\\path")
        try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"a":{"prompt":"{file:./multi.txt}"},"b":{"prompt":"{file:./gone.txt}"}},"instructions":["~/x.md"]}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        #expect(parts.contains { $0.filePath == f.layout.path(".config/opencode/multi.txt") && $0.status == .present })
        #expect(parts.contains { $0.filePath == f.layout.path(".config/opencode/gone.txt") && $0.status == .missing })
        #expect(parts.contains { $0.filePath == f.layout.path("x.md") })
    }

    @Test func opencodeFlagsSymlinkedDuplicate() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".codex/AGENTS.md", "x")
        try f.link(".claude/CLAUDE.md", to: "../.codex/AGENTS.md")
        try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["~/.codex/AGENTS.md"]}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        #expect(parts.filter { $0.notes.contains { $0.hasSuffix("loaded twice") } }.count == 2)
    }

    @Test func opencodeEnvSubstitutionIsLeftUnresolved() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"x":{"prompt":"{env:MY_PROMPT}"}}}"#)
        let agent = InstructionReader.parts(layout: f.layout, harness: .opencode).first { $0.layer == .agentDefinitions }
        #expect(agent?.notes.contains("Set from the environment at runtime") == true)
        #expect(agent?.source == .file(path: f.layout.opencodeConfig, key: "agent.x.prompt"))
    }

    @Test func opencodeEnvDependentFileReferencesStayUnresolved() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["{file:./{env:RULES_FILE}}"],"agent":{"review":{"prompt":"prefix {file:./{env:PROMPT_FILE}} suffix"}},"default_agent":"review"}"#)
        let files = InstructionFiles()
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode, files: files)
        let runtime = parts.filter { $0.notes.contains("Set from the environment at runtime") }
        #expect(runtime.map(\.source) == [
            .file(path: f.layout.opencodeConfig, key: "instructions.0"),
            .file(path: f.layout.opencodeConfig, key: "agent.review.prompt"),
        ])
        #expect(runtime.allSatisfy { $0.status == .present })
        #expect(runtime.last?.notes.contains("Active agent") == true)
        #expect(!parts.contains { $0.filePath?.contains("{env:") == true })
        #expect(files.reads == 1)
    }

    @Test(arguments: ["config.json", "opencode.json", "opencode.jsonc"])
    func opencodeUnquotedEnvPreservesIndependentInstructionsAndAgents(configName: String) throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("rules.md", "rules")
        try f.write(".config/opencode/review.txt", "review prompt")
        try f.write(".config/opencode/\(configName)", #"{"username":"say \"hi\" \\ 🦉","autoupdate":{env:AUTOUPDATE},"instructions":["~/rules.md","{env:RUNTIME_RULES}"],"agent":{"quoted":{"prompt":"say \"hi\" \\ {env:QUOTED_PROMPT}"},"review":{"prompt":"{file:./review.txt}"},"runtime":{"prompt":{env:RUNTIME_PROMPT}}},"default_agent":"review"}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        #expect(parts.contains { $0.filePath == f.layout.path("rules.md") && $0.status == .present })
        let review = try #require(parts.first { $0.filePath == f.layout.path(".config/opencode/review.txt") })
        #expect(review.status == .present)
        #expect(review.notes.contains("Active agent"))
        let runtime = parts.filter { $0.notes.contains("Set from the environment at runtime") }
        #expect(runtime.map(\.source) == [
            .file(path: f.layout.path(".config/opencode/\(configName)"), key: "instructions.1"),
            .file(path: f.layout.path(".config/opencode/\(configName)"), key: "agent.quoted.prompt"),
            .file(path: f.layout.path(".config/opencode/\(configName)"), key: "agent.runtime.prompt"),
        ])
    }

    @Test func opencodeAgentsSharingPromptFileHaveDistinctStableIDs() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/shared.txt", "shared prompt")
        try f.write(".config/opencode/opencode.jsonc", #"{"agent":{"first":{"prompt":"{file:./shared.txt}"},"second":{"prompt":"{file:./shared.txt}"}},"default_agent":"second"}"#)
        let agents = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .agentDefinitions }
        #expect(agents.count == 2)
        #expect(agents.map(\.source) == Array(repeating: .file(path: f.layout.path(".config/opencode/shared.txt"), key: nil), count: 2))
        #expect(Set(agents.map(\.id)).count == 2)
        #expect(agents.allSatisfy { $0.notes.contains { $0.hasSuffix("loaded twice") } })
        #expect(agents.filter { $0.notes.contains("Active agent") }.count == 1)
        let rescanned = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .agentDefinitions }
        #expect(rescanned.map(\.id) == agents.map(\.id))
    }

    @Test func opencodeConfigPrecedenceKeepsWinningKeyProvenance() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/config.json", #"{"instructions":["~/old.md"],"agent":{"old":{"prompt":"{file:old.txt}"}},"default_agent":"fresh"}"#)
        try f.write(".config/opencode/opencode.json", #"{"instructions":["~/middle.md"],"agent":{"fresh":{"prompt":"inline prompt"}}}"#)
        try f.write(".config/opencode/opencode.jsonc", """
        {
          // Last instructions win; agent definitions survive from opencode.json.
          "instructions": ["~/last.md",],
        }
        """)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        #expect(parts.filter { $0.layer == .instructions }.compactMap(\.filePath) == [".claude/CLAUDE.md", "last.md"].map(f.layout.path))
        let agents = parts.filter { $0.layer == .agentDefinitions }
        #expect(agents.count == 1)
        #expect(agents.first?.source == .file(path: f.layout.path(".config/opencode/opencode.json"), key: "agent.fresh.prompt"))
        #expect(agents.first?.notes == ["Replaces the base prompt when this agent is selected", "Active agent"])
    }

    @Test func opencodeInstructionsExpandGlobsAndPreserveMissingLiteralPaths() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/AGENTS.md", "primary")
        try f.write(".claude/CLAUDE.md", "fallback")
        try f.write("rules/b.md", "b")
        try f.write("rules/a.md", "a")
        try f.write(".config/opencode/opencode.json", #"{"instructions":["~/rules/*.md","~/absent.md","~/none/*.md","http://x.dev/plain.md","https://x.dev/secure.md"]}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode)
        let local = parts.filter { $0.layer == .instructions && $0.filePath != nil }
        #expect(local.compactMap(\.filePath) == [".config/opencode/AGENTS.md", "rules/a.md", "rules/b.md", "absent.md"].map(f.layout.path))
        #expect(local.last?.status == .missing)
        #expect(parts.filter { if case .remote(_, nil) = $0.source { true } else { false } }.count == 2)
    }

    @Test func opencodeSubstitutionsTrackKeyPathsAndReuseCanonicalReads() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("shared.txt", "line \"one\"\nC:\\path\t{env:INNER}")
        try f.link(".config/opencode/shared.txt", to: "../../shared.txt")
        try f.write(".config/opencode/opencode.jsonc", """
        {
          // {file:ignored.txt}
          "agent": {
            "a": {"prompt": "prefix {file:./shared.txt} suffix"},
            "b": {"prompt": "{file:~/shared.txt}{file:missing.txt}{env:OUTER}"},
            "inline": {"prompt": "keep me"}
          },
          "default_agent": "b"
        }
        """)
        let files = InstructionFiles()
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode, files: files)
        let agents = parts.filter { $0.layer == .agentDefinitions }
        #expect(agents.count == 4)
        #expect(agents.filter { $0.notes.contains("Active agent") }.compactMap(\.filePath) == [f.layout.path("shared.txt"), f.layout.path(".config/opencode/missing.txt")])
        #expect(agents.first?.notes.contains("Set from the environment at runtime") == false)
        #expect(agents.filter { $0.notes.contains("Set from the environment at runtime") }.count == 2)
        #expect(agents.last?.source == .file(path: f.layout.opencodeConfig, key: "agent.inline.prompt"))
        #expect(!parts.contains { $0.filePath?.hasSuffix("ignored.txt") == true })
        #expect(files.reads == 2)
    }

    @Test func opencodeMarkdownDefaultAgentUsesNestedNameAndFrontmatterName() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/agents/team/deep.md", "nested prompt")
        try f.write(".config/opencode/agent/old.md", "---\nname: renamed\n---\nlegacy prompt")
        try f.write(".config/opencode/opencode.jsonc", #"{"default_agent":"team/deep"}"#)
        let first = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .agentDefinitions }
        #expect(first.filter { $0.notes.contains("Active agent") }.compactMap(\.filePath) == [f.layout.path(".config/opencode/agents/team/deep.md")])
        #expect(first.allSatisfy { $0.notes.contains("Replaces the base prompt when this agent is selected") })
        try f.write(".config/opencode/opencode.jsonc", #"{"default_agent":"renamed"}"#)
        let second = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .agentDefinitions }
        #expect(second.filter { $0.notes.contains("Active agent") }.compactMap(\.filePath) == [f.layout.path(".config/opencode/agent/old.md")])
    }

    @Test func opencodeManySubstitutionsKeepEachInstructionSource() throws {
        let f = try Fixture(); defer { f.remove() }
        var instructions: [String] = []
        for index in 0..<12 {
            try f.write(".config/opencode/prompt-\(index).txt", "prompt \(index)")
            instructions.append("{file:prompt-\(index).txt}")
        }
        let data = try JSONSerialization.data(withJSONObject: ["instructions": instructions], options: .sortedKeys)
        try f.write(".config/opencode/opencode.jsonc", String(decoding: data, as: UTF8.self))
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .instructions }.dropFirst()
        #expect(parts.compactMap(\.filePath) == (0..<12).map { f.layout.path(".config/opencode/prompt-\($0).txt") })
    }

    @Test func opencodeDeduplicatesInstructionPathsButKeepsSymlinkAliases() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("rules/a.md", "a")
        try f.link("alias.md", to: "rules/a.md")
        try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["~/rules/a.md","~/rules/*.md","~/rules/a.md","~/alias.md"]}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.layer == .instructions }.dropFirst()
        #expect(parts.compactMap(\.filePath) == ["rules/a.md", "alias.md"].map(f.layout.path))
        #expect(parts.filter { $0.notes.contains { $0.hasSuffix("loaded twice") } }.count == 2)
    }

    @Test func opencodeAgentTreeStopsAt500AndReadsOnlyFrontmatter() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.link(".config/opencode/agents/loop", to: ".")
        for index in 0..<501 {
            try f.write(String(format: ".config/opencode/agents/%03d.md", index), String(repeating: "x", count: 8_192))
        }
        let files = InstructionFiles()
        let agents = InstructionReader.parts(layout: f.layout, harness: .opencode, files: files).filter { $0.layer == .agentDefinitions && $0.filePath != nil }
        #expect(agents.count == 500)
        #expect(agents.last?.notes.contains("Stopped after 500 rule files") == true)
        #expect(files.reads == 500)
        let firstPath = f.layout.path(".config/opencode/agents/000.md")
        try FileManager.default.removeItem(atPath: firstPath)
        #expect(files.head(firstPath)?.utf8.count == 4_096)
        #expect(files.text(firstPath) == nil)
    }

    @Test func opencodeRuntimeInstructionsRetainEachConfigKey() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".config/opencode/opencode.jsonc", #"{"instructions":["{env:FIRST}","{env:SECOND}"]}"#)
        let parts = InstructionReader.parts(layout: f.layout, harness: .opencode).filter { $0.notes.contains("Set from the environment at runtime") }
        #expect(parts.map(\.source) == [
            .file(path: f.layout.opencodeConfig, key: "instructions.0"),
            .file(path: f.layout.opencodeConfig, key: "instructions.1"),
        ])
    }

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

    @Test func claudeRevisitsImportsReachedThroughFewerHops() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write(".claude/CLAUDE.md", "@a.md @d.md")
        try f.write(".claude/a.md", "@b.md")
        try f.write(".claude/b.md", "@c.md")
        try f.write(".claude/c.md", "@d.md")
        try f.write(".claude/d.md", "@e.md @CLAUDE.md")
        try f.write(".claude/e.md", "@f.md")
        try f.write(".claude/f.md", "@g.md")
        try f.write(".claude/g.md", "@too-deep.md")
        try f.write(".claude/too-deep.md", "x")
        let files = InstructionFiles()
        let parts = InstructionReader.parts(layout: f.layout, harness: .claude, files: files)
        #expect(parts.compactMap(\.filePath) == [
            "CLAUDE.md", "a.md", "b.md", "c.md", "d.md", "e.md", "f.md", "g.md",
        ].map { f.layout.path(".claude/" + $0) })
        #expect(parts.first { $0.filePath == f.layout.path(".claude/d.md") }?.notes == ["Imported by ~/.claude/c.md"])
        #expect(parts.first { $0.filePath == f.layout.path(".claude/e.md") }?.notes == ["Imported by ~/.claude/d.md"])
        #expect(files.reads == 7)
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

    @Test func ruleFrontmatterSurvivesDescriptorLimit() async {
        await #expect(processExitsWith: .success) {
            let f = try Fixture(); defer { f.remove() }
            let claude = "---\npaths: **/*.swift\n---\n" + String(repeating: "x", count: 8_192)
            let antigravity = "---\ntrigger: model_decision\n---\n" + String(repeating: "x", count: 8_192)
            for i in 0..<500 {
                try f.write(".claude/rules/r\(i).md", claude)
                try f.write(".gemini/config/rules/r\(i).md", antigravity)
            }
            var limit = rlimit()
            try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
            limit.rlim_max = min(limit.rlim_max, 256)
            limit.rlim_cur = min(limit.rlim_cur, limit.rlim_max)
            try #require(setrlimit(RLIMIT_NOFILE, &limit) == 0)
            let files = InstructionFiles()
            for harness in [HarnessID.claude, .antigravity] {
                let rules = InstructionReader.parts(layout: f.layout, harness: harness, files: files).filter {
                    $0.filePath?.contains("/rules/") == true
                }
                try #require(rules.count == 500)
                try #require(rules.allSatisfy { $0.status == .present })
                let note = harness == .claude ? "Loads when a matching file is read" : "Conditional: trigger model_decision"
                try #require(rules.allSatisfy { $0.notes.contains(note) })
            }
            #expect(files.reads == 1_000)
        }
    }

    @Test func failedRuleHeadReadIsExplicitAndMemoized() throws {
        let f = try Fixture(); defer { f.remove() }
        for (harness, directory) in [
            (HarnessID.claude, ".claude/rules"), (.antigravity, ".gemini/config/rules"),
        ] {
            let files = InstructionFiles()
            let path = f.layout.path(directory + "/unreadable.md")
            #expect(files.head(path) == nil)
            try f.write(directory + "/unreadable.md", "---\npaths: **/*.swift\ntrigger: model_decision\n---\nx")
            let rule = try #require(InstructionReader.parts(layout: f.layout, harness: harness, files: files).first { $0.filePath == path })
            #expect(rule.status == .missing)
            #expect(rule.notes.contains("Unable to read rule frontmatter"))
            #expect(files.head(path) == nil)
            #expect(files.reads == 0)
        }
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
