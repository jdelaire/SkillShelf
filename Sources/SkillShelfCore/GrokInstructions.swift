import Darwin
import Foundation

extension InstructionReader {
    static func grok(layout: Layout, environment: [String: String], files: InstructionFiles) -> [PromptPart] {
        let home = environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : resolve($0, relativeTo: layout.home, layout: layout) }
            ?? layout.path(".grok")
        let config = TOMLKeys(files.text(home + "/config.toml") ?? "")
        let vendors = ["claude", "cursor"]
        var namedDirectories = [home]
        var ruleDirectories = [home + "/rules"]
        for vendor in vendors {
            let directory = layout.path("." + vendor)
            if config.bool("compat.\(vendor).agents") != false { namedDirectories.append(directory) }
            if config.bool("compat.\(vendor).rules") != false { ruleDirectories.append(directory + "/rules") }
        }
        ruleDirectories += (config.strings("paths.extra_rule_dirs") ?? []).filter {
            $0.hasPrefix("/") || $0.hasPrefix("~/")
        }.map { resolve($0, relativeTo: layout.home, layout: layout) }

        var parts: [PromptPart] = []
        for directory in namedDirectories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in ["Agents.md", "Claude.md", "CLAUDE.md", "CLAUDE.local.md", "AGENT.md", "AGENTS.md"] {
                let actualName: String
                if names.contains(name) {
                    actualName = name
                } else if FileManager.default.fileExists(atPath: directory + "/" + name) {
                    actualName = names.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
                } else {
                    actualName = name
                }
                parts.append(file(directory + "/" + actualName, harness: .grok, layer: .instructions, layout: layout))
            }
        }
        for directory in ruleDirectories {
            parts += rules(directory, recursive: false, harness: .grok, layout: layout, files: files) { _ in [] }
        }
        var identities = Set<GrokFileIdentity>()
        return parts.filter { part in
            guard part.status == .present, let path = part.filePath else { return true }
            var info = stat()
            guard stat(path, &info) == 0 else { return true }
            return identities.insert(GrokFileIdentity(device: info.st_dev, inode: info.st_ino)).inserted
        }
    }
}

private struct GrokFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}
