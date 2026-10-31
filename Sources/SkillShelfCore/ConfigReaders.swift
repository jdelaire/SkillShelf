import Foundation

public enum TOMLValue: Sendable, Equatable {
    case string(String), bool(Bool), strings([String])
}

public struct TOMLKeys: Sendable {
    private let values: [String: TOMLValue]
    public let sections: Set<String>

    public init(_ text: String) {
        var lexer = TOMLLexer(text)
        let parsed = lexer.read()
        values = parsed.values
        sections = parsed.sections
    }

    public subscript(_ key: String) -> TOMLValue? { values[key] }

    public func string(_ key: String) -> String? {
        guard case .string(let value) = values[key] else { return nil }
        return value
    }

    public func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = values[key] else { return nil }
        return value
    }

    public func strings(_ key: String) -> [String]? {
        guard case .strings(let value) = values[key] else { return nil }
        return value
    }
}

private struct TOMLLexer {
    private let input: [Unicode.Scalar]
    private var offset = 0

    init(_ text: String) {
        input = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
    }

    private var current: Unicode.Scalar? {
        offset < input.count ? input[offset] : nil
    }

    mutating func read() -> (values: [String: TOMLValue], sections: Set<String>) {
        var values: [String: TOMLValue] = [:]
        var sections = Set<String>()
        var section: String? = ""
        while offset < input.count {
            skipHorizontalWhitespace()
            let start = offset
            if current == "[" {
                if let name = readSection(), atLineEnd() {
                    section = name
                    sections.insert(name)
                } else {
                    section = nil
                    offset = start
                }
            } else {
                let key = readKey()
                if let value = readValue(), atLineEnd() {
                    if let section, let key {
                        values[section.isEmpty ? key : section + "." + key] = value
                    }
                } else {
                    offset = start
                }
            }
            skipLine()
        }
        return (values, sections)
    }

    private mutating func readSection() -> String? {
        offset += 1
        let start = offset
        while let scalar = current, scalar != "]", scalar != "\n", scalar != "#" {
            offset += 1
        }
        let name = dottedName(input[start..<offset])
        guard consume("]") else { return nil }
        return name
    }

    private mutating func readKey() -> String? {
        let start = offset
        while let scalar = current, scalar != "=", scalar != "\n", scalar != "#" {
            offset += 1
        }
        let name = dottedName(input[start..<offset])
        guard consume("=") else { return nil }
        skipHorizontalWhitespace()
        return name
    }

    private func dottedName(_ scalars: ArraySlice<Unicode.Scalar>) -> String? {
        let parts = String(String.UnicodeScalarView(scalars))
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.allSatisfy({ part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                    || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
            }
        }) else { return nil }
        return parts.joined(separator: ".")
    }

    private mutating func readValue() -> TOMLValue? {
        if current == "\"" || current == "'" { return readString().map(TOMLValue.string) }
        if consume("true") { return .bool(true) }
        if consume("false") { return .bool(false) }
        guard consume("[") else { return nil }
        var values: [String] = []
        skipArrayWhitespace()
        if consume("]") { return .strings(values) }
        while let value = readString() {
            values.append(value)
            skipArrayWhitespace()
            if consume("]") { return .strings(values) }
            guard consume(",") else { return nil }
            skipArrayWhitespace()
            if consume("]") { return .strings(values) }
        }
        return nil
    }

    private mutating func readString() -> String? {
        guard let delimiter = current, delimiter == "\"" || delimiter == "'" else { return nil }
        offset += 1
        let multiline = delimiter == "\"" && consume("\"\"")
        if multiline { _ = consume("\n") }
        var value = String.UnicodeScalarView()
        while let scalar = current {
            if scalar == delimiter {
                offset += 1
                if !multiline { return String(value) }
                let start = offset - 1
                while current == "\"" { offset += 1 }
                let count = offset - start
                if count >= 3 {
                    guard count <= 5 else { return nil }
                    value.append(contentsOf: repeatElement(delimiter, count: count - 3))
                    return String(value)
                }
                value.append(contentsOf: repeatElement(delimiter, count: count))
            } else if delimiter == "\"", scalar == "\\" {
                offset += 1
                guard let escaped = readEscape() else { return nil }
                value.append(escaped)
            } else {
                guard scalar.value >= 0x20 || scalar == "\t" || (multiline && scalar == "\n") else { return nil }
                value.append(scalar)
                offset += 1
            }
        }
        return nil
    }

    private mutating func readEscape() -> Unicode.Scalar? {
        guard let scalar = current else { return nil }
        offset += 1
        switch scalar {
        case "\"", "\\": return scalar
        case "n": return "\n"
        case "t": return "\t"
        case "u":
            guard offset + 4 <= input.count else { return nil }
            let digits = input[offset..<offset + 4]
            guard digits.allSatisfy({
                ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
            }), let number = UInt32(String(String.UnicodeScalarView(digits)), radix: 16),
                let scalar = Unicode.Scalar(number)
            else { return nil }
            offset += 4
            return scalar
        default: return nil
        }
    }

    private mutating func consume(_ token: String) -> Bool {
        let end = offset + token.unicodeScalars.count
        guard end <= input.count, input[offset..<end].elementsEqual(token.unicodeScalars) else { return false }
        offset = end
        return true
    }

    private mutating func skipHorizontalWhitespace() {
        while current == " " || current == "\t" { offset += 1 }
    }

    private mutating func skipArrayWhitespace() {
        while true {
            skipHorizontalWhitespace()
            if current == "\n" {
                offset += 1
            } else if current == "#" {
                skipLine()
            } else {
                return
            }
        }
    }

    private mutating func atLineEnd() -> Bool {
        skipHorizontalWhitespace()
        return current == nil || current == "\n" || current == "#"
    }

    private mutating func skipLine() {
        while let scalar = current, scalar != "\n" { offset += 1 }
        if current == "\n" { offset += 1 }
    }
}

public enum JSONC {
    public static func strip(_ text: String) -> String {
        let input = Array(text.unicodeScalars)
        var uncommented = String.UnicodeScalarView()
        var offset = 0
        var inString = false
        var escaped = false
        while offset < input.count {
            let scalar = input[offset]
            if inString {
                uncommented.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                offset += 1
            } else if scalar == "/", offset + 1 < input.count, input[offset + 1] == "/" {
                uncommented.append(" ")
                offset += 2
                while offset < input.count, input[offset] != "\n", input[offset] != "\r" { offset += 1 }
            } else if scalar == "/", offset + 1 < input.count, input[offset + 1] == "*" {
                uncommented.append(" ")
                offset += 2
                while offset < input.count {
                    if input[offset] == "*", offset + 1 < input.count, input[offset + 1] == "/" {
                        offset += 2
                        break
                    }
                    if input[offset] == "\n" || input[offset] == "\r" { uncommented.append(input[offset]) }
                    offset += 1
                }
            } else {
                uncommented.append(scalar)
                inString = scalar == "\""
                offset += 1
            }
        }

        let scalars = Array(uncommented)
        var result = String.UnicodeScalarView()
        inString = false
        escaped = false
        for index in scalars.indices {
            let scalar = scalars[index]
            if inString {
                result.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
            } else {
                if scalar == "," {
                    var next = index + 1
                    while next < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[next]) { next += 1 }
                    if next < scalars.count, scalars[next] == "}" || scalars[next] == "]" { continue }
                }
                result.append(scalar)
                inString = scalar == "\""
            }
        }
        return String(result)
    }

    public static func object(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(strip(text).utf8)) as? [String: Any]
    }
}
