import Foundation

public enum PromptText: Sendable, Equatable {
    case markdown(String)
    case code(String, language: String)
    case failed(String)
}

public enum PromptContent {
    @concurrent
    public static func load(_ part: PromptPart, fetcher: any PromptFetching) async -> PromptText {
        if case .unavailable(let reason) = part.status { return .failed(reason) }
        do {
            switch part.source {
            case .file(let path, let key):
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let ext = (path as NSString).pathExtension.lowercased()
                if let key {
                    if (path as NSString).lastPathComponent == "models_cache.json", key.hasPrefix("models.") {
                        return .markdown(try modelText(text, slug: String(key.dropFirst("models.".count))))
                    }
                    return .code(try configValue(text, key: key, extension: ext), language: "text")
                }
                return ext == "md" ? .markdown(Frontmatter.body(text)) : .code(text, language: ext.isEmpty ? "text" : ext)
            case .remote(let url, let cache):
                return try await remoteText(url, cache: cache, fetcher: fetcher)
            case .capture(let path):
                return .markdown(captureText(try CaptureRecord.load(path)))
            case .none:
                return .failed("No prompt content available")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func remoteText(_ url: URL, cache: String?, fetcher: any PromptFetching) async throws -> PromptText {
        let file = cache.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            return .markdown(try String(contentsOf: file, encoding: .utf8))
        }
        do {
            let data = try await fetcher.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            if let file {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }
            return .markdown(text)
        } catch {
            if let file, let text = try? String(contentsOf: file, encoding: .utf8) { return .markdown(text) }
            throw error
        }
    }

    private static func configValue(_ text: String, key: String, extension ext: String) throws -> String {
        if ext == "toml", let value = TOMLKeys(text)[key] {
            switch value {
            case .string(let text): return text
            case .bool(let value): return value ? "true" : "false"
            case .strings(let values): return try jsonText(values)
            }
        }
        if ext == "json" || ext == "jsonc",
           let object = JSONC.object(try quotedSubstitutions(text)), let value = jsonValue(object, key: key) {
            return try (value as? String) ?? jsonText(value)
        }
        throw ContentError.valueUnavailable(key)
    }

    private static func jsonValue(_ value: Any, key: String) -> Any? {
        if let object = value as? [String: Any] {
            if let exact = object[key] { return exact }
            for dot in key.indices.reversed() where key[dot] == "." {
                if let child = object[String(key[..<dot])], let found = jsonValue(child, key: String(key[key.index(after: dot)...])) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            let pieces = key.split(separator: ".", maxSplits: 1)
            if let first = pieces.first, let index = Int(first), array.indices.contains(index) {
                return pieces.count == 1 ? array[index] : jsonValue(array[index], key: String(pieces[1]))
            }
        }
        return nil
    }

    private static func quotedSubstitutions(_ text: String) throws -> String {
        let input = Array(JSONC.strip(text))
        var output = ""
        var index = 0
        var inString = false
        var escaped = false
        while index < input.count {
            let character = input[index]
            if !inString, character == "{",
               input[index...].starts(with: "{env:") || input[index...].starts(with: "{file:"),
               let end = input[index...].firstIndex(of: "}") {
                output += try jsonText(String(input[index...end]))
                index = end + 1
                continue
            }
            output.append(character)
            if escaped { escaped = false }
            else if inString && character == "\\" { escaped = true }
            else if character == "\"" { inString.toggle() }
            index += 1
        }
        return output
    }

    private static func modelText(_ text: String, slug: String) throws -> String {
        var parser = OrderedPromptJSONParser(text)
        let root = try parser.parse()
        guard case .array(let models) = root.member("models"),
              let model = models.first(where: {
                  if case .string(let value) = $0.member("slug") { return value == slug }
                  return false
              }),
              let messages = model.member("model_messages") else {
            throw ContentError.valueUnavailable("models." + slug + ".model_messages")
        }
        var sections: [String] = []
        func visit(_ value: OrderedPromptJSON, path: String) {
            switch value {
            case .object(let entries):
                for (key, child) in entries { visit(child, path: path.isEmpty ? key : path + "." + key) }
            case .array(let entries):
                for (index, child) in entries.enumerated() { visit(child, path: path.isEmpty ? String(index) : path + "." + String(index)) }
            case .string(let text):
                sections.append("## \(path.isEmpty ? "model_messages" : path)\n\n\(text)")
            case .other: break
            }
        }
        visit(messages, path: "")
        return sections.joined(separator: "\n\n")
    }

    private static func captureText(_ record: CaptureRecord) -> String {
        var blocks = [
            fenced("Version: \(record.version ?? "Unknown")", language: "text"),
            fenced("Adapter: \(record.adapter)", language: "text"),
        ]
        blocks += record.notes.map { fenced($0, language: "text") }
        let sentinel = record.notes.first { $0.hasPrefix("sentinel: ") }.map { String($0.dropFirst("sentinel: ".count)) }
        let main = sentinel.flatMap { $0.isEmpty ? nil : CaptureParser.mainRequest(record.requests, sentinel: $0) } ?? .unknown
        switch main {
        case .found(let index), .bestGuess(let index):
            if case .bestGuess = main { blocks.append("Main request: best guess") }
            let sections = CaptureParser.sections(record.requests[index].body)
            if let raw = sections.raw {
                blocks.append(fenced(raw, language: "json"))
            } else {
                blocks.append("## System")
                blocks += sections.system.map { fenced($0, language: "text") }
                blocks.append("## Tools (\(sections.tools.count))")
                if !sections.tools.isEmpty {
                    blocks.append(sections.tools.map { "- **\(escapedMetadata($0.name))**: \(escapedMetadata($0.summary))" }.joined(separator: "\n"))
                }
                if let json = sections.toolsJSON { blocks.append(fenced(json, language: "json")) }
                blocks.append("## Messages")
                blocks += sections.messages.map { "### \(escapedMetadata($0.role))\n\n" + fenced($0.text, language: "text") }
            }
            blocks.append("## Helper calls")
            blocks += record.requests.enumerated().filter { $0.offset != index }.map {
                fenced("\($0.element.method) \($0.element.path)", language: "text")
            }
        case .unknown:
            blocks.append("Main request: unknown")
            blocks.append("## Requests")
            for request in record.requests {
                blocks.append("### \(escapedMetadata(request.method)) \(escapedMetadata(request.path))")
                if let encoding = request.bodyEncoding { blocks.append(fenced("Body encoding: " + encoding, language: "text")) }
                let value = try? JSONSerialization.jsonObject(with: Data(request.body.utf8), options: .fragmentsAllowed)
                let body = value.flatMap { try? jsonText($0) } ?? request.body
                blocks.append(fenced(body, language: request.bodyEncoding == nil ? "json" : "text"))
            }
        }
        if let diagnostics = record.diagnostics, !diagnostics.isEmpty {
            blocks.append("## Harness output")
            blocks.append(fenced(diagnostics, language: "text"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private static func escapedMetadata(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                escaped.append(" ")
            } else {
                switch scalar.value {
                case 33...47, 58...64, 91...96, 123...126: escaped.append("\\")
                default: break
                }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func fenced(_ text: String, language: String) -> String {
        var longest = 0
        var count = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            count = byte == 96 || byte == 126 ? (byte == previous ? count + 1 : 1) : 0
            longest = max(longest, count)
            previous = byte
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + text + "\n" + fence
    }

    private enum ContentError: LocalizedError {
        case valueUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .valueUnavailable(let key): "Could not read prompt value: " + key
            }
        }
    }
}

private indirect enum OrderedPromptJSON {
    case object([(String, OrderedPromptJSON)])
    case array([OrderedPromptJSON])
    case string(String)
    case other

    func member(_ key: String) -> OrderedPromptJSON? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.0 == key }?.1
    }
}

private struct OrderedPromptJSONParser {
    private let data: Data
    private let bytes: [UInt8]
    private var offset = 0

    init(_ text: String) {
        data = Data(text.utf8)
        bytes = Array(data)
    }

    mutating func parse() throws -> OrderedPromptJSON {
        _ = try JSONSerialization.jsonObject(with: data)
        return try value()
    }

    private mutating func value() throws -> OrderedPromptJSON {
        whitespace()
        guard offset < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        switch bytes[offset] {
        case 123:
            offset += 1
            var entries: [(String, OrderedPromptJSON)] = []
            whitespace()
            while bytes[offset] != 125 {
                let key = try string()
                whitespace()
                offset += 1
                entries.append((key, try value()))
                whitespace()
                if bytes[offset] != 44 { break }
                offset += 1
                whitespace()
            }
            offset += 1
            return .object(entries)
        case 91:
            offset += 1
            var entries: [OrderedPromptJSON] = []
            whitespace()
            while bytes[offset] != 93 {
                entries.append(try value())
                whitespace()
                if bytes[offset] != 44 { break }
                offset += 1
            }
            offset += 1
            return .array(entries)
        case 34: return .string(try string())
        default:
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            return .other
        }
    }

    private mutating func string() throws -> String {
        let start = offset
        offset += 1
        while offset < bytes.count {
            if bytes[offset] == 92 { offset += 2 }
            else if bytes[offset] == 34 {
                offset += 1
                return try JSONDecoder().decode(String.self, from: data.subdata(in: start..<offset))
            } else { offset += 1 }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
}
