import Foundation

public struct Layout: Sendable {
    public let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = Paths.canonical(home) ?? home
    }

    public func path(_ relative: String) -> String {
        home + "/" + relative
    }

    public var claudeSkills: String { path(".claude/skills") }
    public var claudeSynced: String { path(".claude/skills/synced") }
    public var claudeInstalledPlugins: String { path(".claude/plugins/installed_plugins.json") }
    public var claudeSettings: String { path(".claude/settings.json") }
    public var codexSkills: String { path(".codex/skills") }
    public var codexSystem: String { path(".codex/skills/.system") }
    public var codexPluginCache: String { path(".codex/plugins/cache") }
    public var agentsSkills: String { path(".agents/skills") }
    public var agentsLock: String { path(".agents/.skill-lock.json") }
    public var cursorSkills: String { path(".cursor/skills") }
    public var cursorBuiltIn: String { path(".cursor/skills-cursor") }
    public var opencodeSkills: String { path(".config/opencode/skills") }
    public var opencodeSkill: String { path(".config/opencode/skill") }
    public var opencodeConfig: String { path(".config/opencode/opencode.jsonc") }
    public var grokSkills: String { path(".grok/skills") }
    public var grokBundled: String { path(".grok/bundled/skills") }
    public var grokConfig: String { path(".grok/config.toml") }
    public var grokRegistry: String { path(".grok/installed-plugins/registry.json") }
    public var antigravitySkills: String { path(".gemini/config/skills") }
    public var antigravityCLISkills: String { path(".gemini/antigravity-cli/skills") }
    public var antigravityLegacySkills: String { path(".gemini/antigravity/skills") }
    public var antigravityPlugins: String { path(".gemini/antigravity-cli/plugins") }
    public var museSkills: String { path(".config/muse/skills") }
    public var museBundled: String { path(".local/share/muse/skills/bundled/muse-core/skills") }

    public var protectedPrefixes: [String] {
        [
            claudeSynced, codexSystem, cursorBuiltIn, grokBundled,
            path(".claude/plugins"), path(".codex/plugins"), path(".codex/.tmp"),
            path(".cache/codex-runtimes"), path(".grok/plugins"), path(".grok/installed-plugins"),
            antigravityPlugins, path(".local/share/muse"),
        ]
    }

    public func isInstalled(_ harness: HarnessID) -> Bool {
        harness.detectionPaths.contains { marker in
            FileManager.default.fileExists(atPath: marker.hasPrefix("/") ? marker : path(marker))
        }
    }

    func isInstalledForPrompts(_ harness: HarnessID, environment: [String: String]) -> Bool {
        let home: String
        switch harness {
        case .codex: home = InstructionReader.codexHome(layout: self, environment: environment)
        case .grok: home = InstructionReader.grokHome(layout: self, environment: environment)
        default: return isInstalled(harness)
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func pushRoot(for harness: HarnessID) -> String {
        switch harness {
        case .claude: claudeSkills
        case .codex: agentsSkills
        case .cursor: cursorSkills
        case .opencode: opencodeSkills
        case .grok: grokSkills
        case .antigravity: antigravitySkills
        case .muse: museSkills
        }
    }

    public func display(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

public enum Paths {
    public static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func isInside(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    public static func relative(from directory: String, to target: String) -> String {
        let base = directory.split(separator: "/")
        let destination = target.split(separator: "/")
        var common = 0
        while common < base.count, common < destination.count, base[common] == destination[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: base.count - common)
        return (up + destination[common...].map(String.init)).joined(separator: "/")
    }

    public static func joined(_ directory: String, _ relative: String) -> String {
        var trimmed = relative
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? directory : directory + "/" + trimmed
    }
}
