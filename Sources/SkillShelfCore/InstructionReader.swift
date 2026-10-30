import Foundation

public final class InstructionFiles {
    private var cache: [String: CachedFile] = [:]
    private(set) var reads = 0

    public init() {}

    public func text(_ path: String) -> String? {
        load(path, upTo: nil).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func head(_ path: String, bytes: Int = 4096) -> String? {
        load(path, upTo: max(0, bytes)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func load(_ path: String, upTo limit: Int?) -> Data? {
        let key = Paths.canonical(path) ?? URL(fileURLWithPath: path).standardized.path
        let entry: CachedFile
        if let cached = cache[key] {
            entry = cached
        } else {
            entry = CachedFile(key)
            cache[key] = entry
        }
        let hadRead = entry.hasRead
        let data = entry.load(upTo: limit)
        if !hadRead, entry.hasRead { reads += 1 }
        return data
    }

    private final class CachedFile {
        let path: String
        var data: Data?
        var hasRead = false
        var complete = false

        init(_ path: String) {
            self.path = path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { return }
            data = Data()
        }

        func load(upTo limit: Int?) -> Data? {
            guard var buffer = data else { return nil }
            if !complete, limit.map({ buffer.count < $0 }) ?? true {
                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    hasRead = true
                    try handle.seek(toOffset: UInt64(buffer.count))
                    if let limit {
                        buffer.append(try handle.read(upToCount: limit - buffer.count) ?? Data())
                        complete = buffer.count < limit
                    } else {
                        buffer.append(try handle.readToEnd() ?? Data())
                        complete = true
                    }
                    data = buffer
                } catch {
                    data = nil
                    return nil
                }
            }
            return limit.map { Data(buffer.prefix($0)) } ?? buffer
        }
    }
}

public enum InstructionReader {
    public static func parts(
        layout: Layout,
        harness: HarnessID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        files: InstructionFiles = InstructionFiles()
    ) -> [PromptPart] {
        let parts: [PromptPart]
        switch harness {
        case .claude:
            parts = claude(layout: layout, files: files)
        case .codex:
            parts = codex(layout: layout, environment: environment, files: files)
        case .cursor:
            parts = [PromptPart(
                harness: .cursor, layer: .instructions, title: "User rules", source: .none,
                status: .unavailable("Managed in Cursor Settings > Rules")
            )]
        case .antigravity:
            parts = antigravity(layout: layout, files: files)
        case .muse:
            parts = muse(layout: layout, environment: environment, files: files)
        case .grok:
            parts = grok(layout: layout, environment: environment, files: files)
        case .opencode:
            parts = opencode(layout: layout, files: files)
        }
        return markDuplicates(parts)
    }

    static func file(
        _ path: String,
        harness: HarnessID,
        layer: PromptLayer,
        layout: Layout,
        notes: [String] = []
    ) -> PromptPart {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let readable = exists && !isDirectory.boolValue && FileManager.default.isReadableFile(atPath: path)
        return PromptPart(
            harness: harness, layer: layer, title: layout.display(path), source: .file(path: path, key: nil),
            status: readable ? .present : .missing, notes: notes
        )
    }

    static func markDuplicates(_ parts: [PromptPart]) -> [PromptPart] {
        var groups: [String: [Int]] = [:]
        for (index, part) in parts.enumerated() where part.status == .present {
            guard let path = part.filePath, let canonical = Paths.canonical(path) else { continue }
            groups[canonical, default: []].append(index)
        }
        var result = parts
        for indices in groups.values where indices.count > 1 {
            for index in indices {
                let other = indices[0] == index ? indices[1] : indices[0]
                result[index] = parts[index].addingNotes(["Same file as \(parts[other].title), loaded twice"])
            }
        }
        return result
    }

    static func resolve(_ path: String, relativeTo directory: String, layout: Layout) -> String {
        let expanded: String
        if path == "~" {
            expanded = layout.home
        } else if path.hasPrefix("~/") {
            expanded = layout.home + path.dropFirst()
        } else {
            expanded = path.hasPrefix("/") ? path : directory + "/" + path
        }
        return URL(fileURLWithPath: expanded).standardized.path
    }

    static func codexHome(layout: Layout, environment: [String: String]) -> String {
        guard let home = environment["CODEX_HOME"], !home.isEmpty else { return layout.path(".codex") }
        return resolve(home, relativeTo: layout.home, layout: layout)
    }

    static func configPart(_ path: String, key: String, harness: HarnessID) -> PromptPart {
        PromptPart(
            harness: harness, layer: .instructions, title: "\((path as NSString).lastPathComponent) › \(key)",
            source: .file(path: path, key: key), status: .present
        )
    }

    static func rules(
        _ directory: String,
        recursive: Bool,
        harness: HarnessID,
        layout: Layout,
        files: InstructionFiles,
        notes: ([String: String]) -> [String]
    ) -> [PromptPart] {
        var parts: [PromptPart] = []
        var visited = Set<String>()
        func visit(_ directory: String) {
            guard parts.count < 500, let canonical = Paths.canonical(directory), visited.insert(canonical).inserted,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
            else { return }
            for name in names.sorted() {
                guard parts.count < 500 else { return }
                let path = directory + "/" + name
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    if recursive { visit(path) }
                } else if (name as NSString).pathExtension.lowercased() == "md" {
                    if let head = files.head(path) {
                        parts.append(file(path, harness: harness, layer: .instructions, layout: layout, notes: notes(Frontmatter.parse(head))))
                    } else {
                        parts.append(PromptPart(
                            harness: harness, layer: .instructions, title: layout.display(path), source: .file(path: path, key: nil),
                            status: .missing, notes: ["Unable to read rule frontmatter"]
                        ))
                    }
                }
            }
        }
        visit(directory)
        if parts.count == 500 {
            parts[499] = parts[499].addingNotes(["Stopped after 500 rule files"])
        }
        return parts
    }

    private static func codex(layout: Layout, environment: [String: String], files: InstructionFiles) -> [PromptPart] {
        let home = codexHome(layout: layout, environment: environment)
        let override = home + "/AGENTS.override.md"
        let path = files.text(override).map { !$0.isEmpty } == true ? override : home + "/AGENTS.md"
        var parts = [file(path, harness: .codex, layer: .instructions, layout: layout)]
        let config = home + "/config.toml"
        let keys = TOMLKeys(files.text(config) ?? "")
        for key in ["instructions", "developer_instructions"] where keys.string(key) != nil {
            parts.append(configPart(config, key: key, harness: .codex))
        }
        if let instructionFile = keys.string("model_instructions_file") {
            parts.append(file(
                resolve(instructionFile, relativeTo: home, layout: layout), harness: .codex, layer: .instructions,
                layout: layout, notes: ["Replaces the base prompt"]
            ))
        }
        return parts
    }

    private static func antigravity(layout: Layout, files: InstructionFiles) -> [PromptPart] {
        var parts = [".gemini/AGENTS.md", ".gemini/GEMINI.md", ".gemini/config/AGENTS.md", ".gemini/config/GEMINI.md"].map {
            file(layout.path($0), harness: .antigravity, layer: .instructions, layout: layout)
        }
        for directory in [".gemini/config/rules", ".gemini/antigravity-cli/rules"] {
            parts += rules(layout.path(directory), recursive: false, harness: .antigravity, layout: layout, files: files) { fields in
                guard let trigger = fields["trigger"], trigger != "always_on" else { return [] }
                return ["Conditional: trigger \(trigger)"]
            }
        }
        return parts
    }

    private static func muse(layout: Layout, environment: [String: String], files: InstructionFiles) -> [PromptPart] {
        let config = layout.path(".config/muse/settings.json")
        let settings = files.text(config).flatMap(JSONC.object) ?? [:]
        let run = settings["run"] as? [String: Any] ?? [:]
        var parts = ["system_prompt", "developer_prompt"].compactMap { key in
            run[key] as? String == nil ? nil : configPart(config, key: "run." + key, harness: .muse)
        }
        let context = settings["context"] as? [String: Any]
        if context?["foreign_personal_rules"] as? Bool != false {
            for path in [layout.path(".claude/CLAUDE.md"), codexHome(layout: layout, environment: environment) + "/AGENTS.md"] {
                parts.append(file(path, harness: .muse, layer: .instructions, layout: layout))
            }
        }
        return parts
    }
}
