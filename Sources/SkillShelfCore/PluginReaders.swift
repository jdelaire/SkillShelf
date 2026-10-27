import Foundation

public enum PluginReaders {
    static let codexBuiltInMarketplaces: Set<String> = ["openai-bundled", "openai-primary-runtime"]

    public static func claudeRoots(installed: Data?, settings: Data?) -> [Root] {
        guard
            let installed,
            let object = try? JSONSerialization.jsonObject(with: installed) as? [String: Any],
            let plugins = object["plugins"] as? [String: Any]
        else { return [] }
        let settingsObject = settings.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let enabled = settingsObject?["enabledPlugins"] as? [String: Any] ?? [:]
        var roots: [Root] = []
        for id in plugins.keys.sorted() {
            guard (enabled[id] as? Bool) == true, let installs = plugins[id] as? [[String: Any]] else { continue }
            for install in installs where install["scope"] as? String == "user" {
                guard let installPath = install["installPath"] as? String else { continue }
                let manifest = installPath + "/.claude-plugin/plugin.json"
                let ref = PluginRef(owner: .claude, id: id, removable: true)
                for skillsPath in manifestSkillPaths(manifest) {
                    roots.append(Root(path: Paths.joined(installPath, skillsPath), kind: .plugin, plugin: ref))
                }
            }
        }
        return roots
    }

    public static func codexRoots(listJSON: Data, cache: String) -> [Root] {
        guard
            let object = try? JSONSerialization.jsonObject(with: listJSON) as? [String: Any],
            let installed = object["installed"] as? [[String: Any]]
        else { return [] }
        var roots: [Root] = []
        for plugin in installed {
            guard
                plugin["installed"] as? Bool == true,
                plugin["enabled"] as? Bool == true,
                let id = plugin["pluginId"] as? String,
                let name = plugin["name"] as? String,
                let marketplace = plugin["marketplaceName"] as? String
            else { continue }
            let version = plugin["version"] as? String
            let source = plugin["source"] as? [String: Any]
            let candidates = [
                version.map { "\(cache)/\(marketplace)/\(name)/\($0)" },
                "\(cache)/\(marketplace)/\(name)/latest",
                source?["source"] as? String == "local" ? source?["path"] as? String : nil,
            ].compactMap { $0 }
            guard let payload = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            let ref = PluginRef(owner: .codex, id: id, removable: !codexBuiltInMarketplaces.contains(marketplace))
            for skillsPath in manifestSkillPaths(payload + "/.codex-plugin/plugin.json") {
                roots.append(Root(path: Paths.joined(payload, skillsPath), kind: .plugin, plugin: ref))
            }
        }
        return roots
    }

    static func manifestSkillPaths(_ manifest: String) -> [String] {
        guard
            let data = FileManager.default.contents(atPath: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["skills"] }
        if let single = object["skills"] as? String { return [single] }
        if let many = object["skills"] as? [String], !many.isEmpty { return many }
        return ["skills"]
    }

    public struct GrokCompat: Sendable, Equatable {
        public var claudeSkills = true
        public var cursorSkills = true
        public var hasSkillsSection = false

        public init() {}
    }

    public static func grokCompat(config: String?) -> GrokCompat {
        var compat = GrokCompat()
        guard let config else { return compat }
        var section = ""
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if section == "skills" { compat.hasSkillsSection = true }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "skills" else { continue }
            let value = parts[1].hasPrefix("false")
            if section == "compat.claude" { compat.claudeSkills = !value }
            if section == "compat.cursor" { compat.cursorSkills = !value }
        }
        return compat
    }
}
