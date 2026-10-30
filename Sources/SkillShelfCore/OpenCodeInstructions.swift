import Darwin
import Foundation

extension InstructionReader {
    static func opencode(layout: Layout, files: InstructionFiles) -> [PromptPart] {
        let directory = layout.path(".config/opencode")
        var values: [String: OpenCodeConfig] = [:]
        for name in ["config.json", "opencode.json", "opencode.jsonc"] {
            let path = directory + "/" + name
            guard let text = files.text(path), let config = OpenCodeConfig(text: text, path: path, layout: layout, files: files) else { continue }
            for key in config.object.keys { values[key] = config }
        }
        let primary = file(directory + "/AGENTS.md", harness: .opencode, layer: .instructions, layout: layout)
        var parts = [primary.status == .present ? primary : file(layout.path(".claude/CLAUDE.md"), harness: .opencode, layer: .instructions, layout: layout)]
        if let config = values["instructions"], let entries = config.object["instructions"] as? [String] {
            for (index, entry) in entries.enumerated() {
                let keyPath = ["instructions", String(index)]
                if let substituted = config.parts(at: keyPath, layer: .instructions, layout: layout, notes: []) {
                    parts += substituted
                } else if let url = URL(string: entry), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                    parts.append(PromptPart(harness: .opencode, layer: .instructions, title: entry, source: .remote(url: url, cache: nil), status: .present))
                } else {
                    let pattern = resolve(entry, relativeTo: directory, layout: layout)
                    for path in openCodeGlob(pattern) {
                        parts.append(file(path, harness: .opencode, layer: .instructions, layout: layout))
                    }
                }
            }
        }
        var instructionPaths = Set<String>()
        parts = parts.filter { part in
            guard case .file(let path, nil) = part.source else { return true }
            return instructionPaths.insert(path).inserted
        }
        let defaultAgent = values["default_agent"]?.object["default_agent"] as? String
        let replacement = "Replaces the base prompt when this agent is selected"
        for root in ["agents", "agent"] {
            let base = directory + "/" + root
            parts += openCodeAgents(base, layout: layout, files: files, defaultAgent: defaultAgent, replacement: replacement)
        }
        if let config = values["agent"], let agents = config.object["agent"] as? [String: Any] {
            for name in agents.keys.sorted() {
                guard let agent = agents[name] as? [String: Any], agent["prompt"] is String else { continue }
                let keyPath = ["agent", name, "prompt"]
                let notes = [replacement] + (name == defaultAgent ? ["Active agent"] : [])
                parts += config.parts(at: keyPath, layer: .agentDefinitions, layout: layout, notes: notes)
                    ?? [config.part(at: keyPath, layer: .agentDefinitions, notes: notes)]
            }
        }
        if defaultAgent == nil {
            parts.append(PromptPart(
                harness: .opencode, layer: .agentDefinitions,
                title: "OpenCode uses the first enabled primary agent. Capture shows which.", source: .none,
                status: .unavailable("No default_agent set")
            ))
        }
        return parts
    }

    private static func openCodeGlob(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        let result = pattern.withCString { Darwin.glob($0, 0, nil, &matches) }
        if result == GLOB_NOMATCH {
            return pattern.contains { "*?[".contains($0) } ? [] : [pattern]
        }
        guard result == 0, let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { paths[$0].map { String(cString: $0) } }.sorted()
    }

    private static func openCodeAgents(
        _ directory: String, layout: Layout, files: InstructionFiles, defaultAgent: String?, replacement: String
    ) -> [PromptPart] {
        var parts: [PromptPart] = []
        var visited = Set<String>()
        func visit(_ path: String) {
            guard parts.count < 500, let canonical = Paths.canonical(path), visited.insert(canonical).inserted,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in names.sorted() {
                guard parts.count < 500 else { return }
                let child = path + "/" + name
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    visit(child)
                } else if (name as NSString).pathExtension.lowercased() == "md" {
                    let head = files.head(child)
                    let relative = String(child.dropFirst(directory.count + 1))
                    let agentName = head.flatMap { Frontmatter.parse($0)["name"] }
                        ?? (relative as NSString).deletingPathExtension
                    let notes = [replacement] + (agentName == defaultAgent ? ["Active agent"] : [])
                    let part = file(child, harness: .opencode, layer: .agentDefinitions, layout: layout, notes: notes)
                    parts.append(head == nil ? PromptPart(
                        harness: .opencode, layer: .agentDefinitions, title: part.title, source: part.source,
                        status: .missing, notes: notes + ["Unable to read agent frontmatter"]
                    ) : part)
                }
            }
        }
        visit(directory)
        if parts.count == 500 { parts[499] = parts[499].addingNotes(["Stopped after 500 rule files"]) }
        return parts
    }
}

private struct OpenCodeConfig {
    let path: String
    let object: [String: Any]
    let references: [[String]: [OpenCodeReference]]

    init?(text: String, path: String, layout: Layout, files: InstructionFiles) {
        guard let regex = try? NSRegularExpression(pattern: #"\{(file|env):([^}]+)\}"#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if matches.isEmpty {
            guard let object = JSONC.object(text) else { return nil }
            self.path = path
            self.object = object
            references = [:]
            return
        }
        let prefix = "SKILLSHELF_" + UUID().uuidString + "_"
        guard let marker = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: prefix) + #"(\d+)_END"#) else { return nil }
        let marked = NSMutableString(string: text)
        for (index, match) in matches.enumerated().reversed() {
            marked.replaceCharacters(in: match.range, with: prefix + String(index) + "_END")
        }
        guard let markedObject = JSONC.object(marked as String) else { return nil }
        var keyPaths: [Int: [String]] = [:]
        func visit(_ value: Any, at keyPath: [String]) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary { visit(child, at: keyPath + [key]) }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { visit(child, at: keyPath + [String(index)]) }
            } else if let string = value as? String {
                for match in marker.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                    if let index = Int((string as NSString).substring(with: match.range(at: 1))) { keyPaths[index] = keyPath }
                }
            }
        }
        visit(markedObject, at: [])
        let expanded = NSMutableString(string: text)
        let source = text as NSString
        var references: [OpenCodeReference] = []
        for (index, match) in matches.enumerated().reversed() {
            guard let keyPath = keyPaths[index] else { continue }
            let kind = source.substring(with: match.range(at: 1))
            if kind == "env" {
                references.append(OpenCodeReference(keyPath: keyPath, file: nil, status: .present))
            } else {
                let directory = (path as NSString).deletingLastPathComponent
                let target = InstructionReader.resolve(source.substring(with: match.range(at: 2)), relativeTo: directory, layout: layout)
                let content = files.text(target)
                let trimmed = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = try? JSONSerialization.data(withJSONObject: trimmed, options: .fragmentsAllowed),
                      let quoted = String(data: data, encoding: .utf8) else { return nil }
                expanded.replaceCharacters(in: match.range, with: String(quoted.dropFirst().dropLast()))
                references.append(OpenCodeReference(keyPath: keyPath, file: target, status: content == nil ? .missing : .present))
            }
        }
        guard let object = JSONC.object(expanded as String) else { return nil }
        self.path = path
        self.object = object
        self.references = Dictionary(grouping: references.reversed(), by: \.keyPath)
    }

    func part(at keyPath: [String], layer: PromptLayer, notes: [String]) -> PromptPart {
        let key = keyPath.joined(separator: ".")
        return PromptPart(
            harness: .opencode, layer: layer, title: "\((path as NSString).lastPathComponent) › \(key)",
            source: .file(path: path, key: key), status: .present, notes: notes
        )
    }

    func parts(at keyPath: [String], layer: PromptLayer, layout: Layout, notes: [String]) -> [PromptPart]? {
        let matches = references[keyPath] ?? []
        guard !matches.isEmpty else { return nil }
        let notes = notes + (matches.contains { $0.file == nil } ? ["Set from the environment at runtime"] : [])
        var seen = Set<String>()
        let parts = matches.compactMap { reference -> PromptPart? in
            guard let file = reference.file, seen.insert(file).inserted else { return nil }
            return PromptPart(
                harness: .opencode, layer: layer, title: layout.display(file), source: .file(path: file, key: nil),
                status: reference.status, notes: notes + ["via {file:} in \((path as NSString).lastPathComponent)"]
            )
        }
        return parts.isEmpty ? [part(at: keyPath, layer: layer, notes: notes)] : parts
    }
}

private struct OpenCodeReference {
    let keyPath: [String]
    let file: String?
    let status: PromptStatus
}
