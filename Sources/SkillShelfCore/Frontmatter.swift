import Foundation

public enum Frontmatter {
    public static func parse(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix(">") || value.hasPrefix("|") {
                var parts: [String] = []
                while index < lines.count, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                    parts.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = parts.joined(separator: " ")
            }
            fields[key] = unquote(value)
        }
        return fields
    }

    public static func body(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }
}
