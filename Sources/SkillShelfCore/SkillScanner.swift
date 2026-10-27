import Foundation

public enum SkillScanner {
    public struct Inputs: Sendable {
        public var claudePluginRoots: [Root]
        public var codexPluginRoots: [Root]
        public var grokCompat: PluginReaders.GrokCompat
        public var notes: [String]

        public init(
            claudePluginRoots: [Root] = [],
            codexPluginRoots: [Root] = [],
            grokCompat: PluginReaders.GrokCompat = .init(),
            notes: [String] = []
        ) {
            self.claudePluginRoots = claudePluginRoots
            self.codexPluginRoots = codexPluginRoots
            self.grokCompat = grokCompat
            self.notes = notes
        }
    }

    @concurrent
    public static func scan(layout: Layout, runner: any CommandRunning, generation: Int) async -> Snapshot {
        let files = FileManager.default
        var notes: [String] = []
        let claudePlugins = PluginReaders.claudeRoots(
            installed: files.contents(atPath: layout.claudeInstalledPlugins),
            settings: files.contents(atPath: layout.claudeSettings)
        )
        var codexPlugins: [Root] = []
        if layout.isInstalled(.codex) {
            do {
                let result = try await runner.run("codex", ["plugin", "list", "--json"])
                if result.status == 0 {
                    codexPlugins = PluginReaders.codexRoots(listJSON: Data(result.output.utf8), cache: layout.codexPluginCache)
                } else {
                    notes.append("Codex plugins not listed: `codex plugin list` exited with \(result.status).")
                }
            } catch {
                notes.append("Codex plugins not listed: \(error.localizedDescription)")
            }
        }
        let grokConfig = files.contents(atPath: layout.grokConfig).map { String(decoding: $0, as: UTF8.self) }
        let compat = PluginReaders.grokCompat(config: grokConfig)
        if compat.hasSkillsSection {
            notes.append("Grok has a [skills] section in config.toml. Extra paths and disabled skills there are not reflected.")
        }
        if let opencode = files.contents(atPath: layout.opencodeConfig), String(decoding: opencode, as: UTF8.self).contains("\"skills\"") {
            notes.append("OpenCode config sets skills options. Extra paths there are not reflected.")
        }
        if files.fileExists(atPath: layout.grokRegistry) {
            notes.append("Grok plugin skills are not listed yet.")
        }
        let inputs = Inputs(claudePluginRoots: claudePlugins, codexPluginRoots: codexPlugins, grokCompat: compat, notes: notes)
        return snapshot(layout: layout, inputs: inputs, generation: generation)
    }

    public static func harnessRoots(layout: Layout, inputs: Inputs) -> [HarnessID: [HarnessRoot]] {
        let user = { (path: String) in Root(path: path, kind: .user) }
        let synced = subdirectories(layout.claudeSynced).map { Root(path: $0, kind: .managed) }
        let claudeSkills = user(layout.claudeSkills)
        let codexSkills = user(layout.codexSkills)
        let agents = user(layout.agentsSkills)
        let cursorSkills = user(layout.cursorSkills)
        let grokSkills = user(layout.grokSkills)

        var grok = [HarnessRoot(root: grokSkills), HarnessRoot(root: agents)]
        if inputs.grokCompat.claudeSkills { grok.append(HarnessRoot(root: claudeSkills)) }
        if inputs.grokCompat.cursorSkills { grok.append(HarnessRoot(root: cursorSkills)) }
        grok.append(HarnessRoot(root: Root(path: layout.grokBundled, kind: .builtIn)))

        let all: [HarnessID: [HarnessRoot]] = [
            .claude: [HarnessRoot(root: claudeSkills)]
                + synced.map { HarnessRoot(root: $0) }
                + inputs.claudePluginRoots.map { HarnessRoot(root: $0) },
            .codex: [HarnessRoot(root: codexSkills), HarnessRoot(root: agents),
                     HarnessRoot(root: Root(path: layout.codexSystem, kind: .builtIn))]
                + inputs.codexPluginRoots.map { HarnessRoot(root: $0) },
            .cursor: [HarnessRoot(root: cursorSkills), HarnessRoot(root: agents),
                      HarnessRoot(root: Root(path: layout.cursorBuiltIn, kind: .builtIn)),
                      HarnessRoot(root: claudeSkills, thirdParty: true),
                      HarnessRoot(root: codexSkills, thirdParty: true),
                      HarnessRoot(root: grokSkills, thirdParty: true)]
                + inputs.claudePluginRoots.map { HarnessRoot(root: $0, thirdParty: true) },
            .opencode: [HarnessRoot(root: user(layout.opencodeSkills)), HarnessRoot(root: user(layout.opencodeSkill)),
                        HarnessRoot(root: claudeSkills), HarnessRoot(root: agents)],
            .grok: grok,
            .antigravity: [HarnessRoot(root: user(layout.antigravitySkills)),
                           HarnessRoot(root: user(layout.antigravityCLISkills)),
                           HarnessRoot(root: user(layout.antigravityLegacySkills))]
                + subdirectories(layout.antigravityPlugins).map {
                    let name = ($0 as NSString).lastPathComponent
                    return HarnessRoot(root: Root(
                        path: $0 + "/skills", kind: .plugin,
                        plugin: PluginRef(owner: .antigravity, id: name, removable: false)
                    ))
                },
        ]
        return all.filter { layout.isInstalled($0.key) }
    }

    public static func snapshot(layout: Layout, inputs: Inputs, generation: Int) -> Snapshot {
        let harnessRoots = harnessRoots(layout: layout, inputs: inputs)
        var seen = Set<String>()
        var roots: [Root] = []
        for harness in HarnessID.allCases {
            for harnessRoot in harnessRoots[harness] ?? [] where seen.insert(harnessRoot.root.path).inserted {
                roots.append(harnessRoot.root)
            }
        }
        let guarded = roots.filter { $0.kind != .user }
        let entries = roots.flatMap { scanRoot($0, guarded: guarded, layout: layout) }
        return Snapshot(generation: generation, entries: entries, harnessRoots: harnessRoots, notes: inputs.notes)
    }

    static func scanRoot(_ root: Root, guarded: [Root], layout: Layout) -> [SkillEntry] {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        var entries: [SkillEntry] = []
        for folder in names.sorted() where !folder.hasPrefix(".") {
            let entryPath = root.path + "/" + folder
            let destination = try? files.destinationOfSymbolicLink(atPath: entryPath)
            let resolved = Paths.canonical(entryPath)
            if let resolved {
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue,
                      files.fileExists(atPath: resolved + "/SKILL.md")
                else { continue }
            } else if destination == nil {
                continue
            }
            let fields = resolved
                .flatMap { files.contents(atPath: $0 + "/SKILL.md") }
                .map { Frontmatter.parse(String(decoding: $0, as: UTF8.self)) } ?? [:]
            entries.append(SkillEntry(
                root: root,
                folderName: folder,
                entryPath: entryPath,
                linkDestination: destination,
                resolvedPath: resolved,
                name: fields["name"] ?? folder,
                description: fields["description"] ?? "",
                protection: resolved.map { protection(for: $0, guarded: guarded, layout: layout) } ?? .none
            ))
        }
        return entries
    }

    static func protection(for resolved: String, guarded: [Root], layout: Layout) -> Protection {
        let canonicalGuarded = guarded.map { (root: $0, path: Paths.canonical($0.path) ?? $0.path) }
        for item in canonicalGuarded where item.root.kind == .plugin && Paths.isInside(resolved, item.path) {
            if let plugin = item.root.plugin { return .plugin(plugin) }
        }
        for item in canonicalGuarded where Paths.isInside(resolved, item.path) {
            switch item.root.kind {
            case .managed: return .managed
            case .builtIn: return .builtIn
            case .plugin, .user: break
            }
        }
        for prefix in layout.protectedPrefixes {
            let canonicalPrefix = Paths.canonical(prefix) ?? prefix
            if Paths.isInside(resolved, canonicalPrefix) {
                return Paths.isInside(resolved, Paths.canonical(layout.claudeSynced) ?? layout.claudeSynced) ? .managed : .builtIn
            }
        }
        return .none
    }

    static func subdirectories(_ path: String) -> [String] {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: path) else { return [] }
        return names.sorted().filter { !$0.hasPrefix(".") }.map { path + "/" + $0 }.filter {
            var isDirectory: ObjCBool = false
            return files.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
