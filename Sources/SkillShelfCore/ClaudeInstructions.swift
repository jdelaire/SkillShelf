import Foundation

extension InstructionReader {
    static func claude(layout: Layout, files: InstructionFiles) -> [PromptPart] {
        var parts: [PromptPart] = []
        var visited = Set<String>()
        func visit(_ path: String, depth: Int, parent: String?) {
            let canonical = Paths.canonical(path) ?? URL(fileURLWithPath: path).standardized.path
            guard visited.insert(canonical).inserted else { return }
            let part = file(
                path, harness: .claude, layer: .instructions, layout: layout,
                notes: parent.map { ["Imported by \($0)"] } ?? []
            )
            parts.append(part)
            guard depth < 4, part.status == .present,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: canonical),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
                  let text = files.text(path)
            else { return }
            let directory = (path as NSString).deletingLastPathComponent
            for imported in claudeImports(text) {
                visit(resolve(imported, relativeTo: directory, layout: layout), depth: depth + 1, parent: part.title)
            }
        }
        visit(layout.path(".claude/CLAUDE.md"), depth: 0, parent: nil)
        parts += rules(layout.path(".claude/rules"), recursive: true, harness: .claude, layout: layout, files: files) { fields in
            fields["paths"] == nil ? [] : ["Loads when a matching file is read"]
        }
        if let style = claudeOutputStyle(layout: layout, files: files) { parts.append(style) }
        return parts
    }

    private static func claudeImports(_ text: String) -> [String] {
        var fence: (character: Character, length: Int)?
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indentation = line.prefix { $0 == " " }.count
            let trimmed = line.dropFirst(indentation)
            if indentation <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let length = trimmed.prefix { $0 == first }.count
                if let current = fence {
                    if first == current.character, length >= current.length,
                       trimmed.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fence = nil
                    }
                } else if length >= 3 {
                    fence = (first, length)
                } else {
                    lines.append(String(line))
                }
            } else if fence == nil {
                lines.append(String(line))
            }
        }
        let content = lines.joined(separator: "\n")
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w`])@([~./\w-][^\s`]*)"#) else { return [] }
        return regex.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap {
            Range($0.range(at: 1), in: content).map { String(content[$0]) }
        }
    }

    private static func claudeOutputStyle(layout: Layout, files: InstructionFiles) -> PromptPart? {
        guard let settings = files.text(layout.claudeSettings).flatMap(JSONC.object),
              let name = settings["outputStyle"] as? String,
              name.caseInsensitiveCompare("default") != .orderedSame
        else { return nil }
        let directory = layout.path(".claude/output-styles")
        if let match = (try? FileManager.default.contentsOfDirectory(atPath: directory))?.sorted().first(where: {
            let path = $0 as NSString
            return path.pathExtension.lowercased() == "md" && path.deletingPathExtension.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return file(directory + "/" + match, harness: .claude, layer: .instructions, layout: layout)
        }
        return PromptPart(
            harness: .claude, layer: .instructions, title: "Output style: \(name)", source: .none,
            status: .unavailable("Built-in style")
        )
    }
}
