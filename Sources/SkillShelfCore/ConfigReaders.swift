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
    private struct Key {
        let name: String?
    }

    private struct StringToken {
        let delimiter: Unicode.Scalar
        let multiline: Bool
        let content: Range<Int>
        let closingQuotes: Int
    }

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
            if current == "[" {
                if let name = readSection(), atLineEnd() {
                    section = name
                    sections.insert(name)
                } else {
                    section = nil
                }
            } else if let key = readDottedKey(), consume("=") {
                skipHorizontalWhitespace()
                if let range = lexValue(), atLineEnd(),
                    let section, let name = key.name, let value = decodeValue(range) {
                    values[section.isEmpty ? name : section + "." + name] = value
                }
            }
            skipLine()
        }
        return (values, sections)
    }

    private mutating func readSection() -> String? {
        offset += 1
        let arrayTable = consume("[")
        guard let key = readDottedKey(), consume("]") else { return nil }
        if arrayTable { _ = consume("]") }
        return arrayTable ? nil : key.name
    }

    private mutating func readDottedKey() -> Key? {
        var parts: [String] = []
        var supported = true
        while true {
            skipHorizontalWhitespace()
            if current == "\"" || current == "'" {
                guard lexString(allowMultiline: false) != nil else { return nil }
                supported = false
            } else {
                let start = offset
                while let scalar = current,
                    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                        || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-" {
                    offset += 1
                }
                guard offset > start else { return nil }
                parts.append(String(String.UnicodeScalarView(input[start..<offset])))
            }
            skipHorizontalWhitespace()
            if !consume(".") { return Key(name: supported ? parts.joined(separator: ".") : nil) }
        }
    }

    private mutating func lexValue() -> Range<Int>? {
        let start = offset
        if current == "\"" || current == "'" {
            guard lexString() != nil else { return nil }
        } else if current == "[" || current == "{" {
            guard lexContainer() else { return nil }
        } else {
            while let scalar = current, scalar != "\n", scalar != "#",
                scalar != ",", scalar != "]", scalar != "}" {
                offset += 1
            }
        }
        return offset > start ? start..<offset : nil
    }

    private mutating func lexContainer() -> Bool {
        var closers: [Unicode.Scalar] = []
        while let scalar = current {
            switch scalar {
            case "\"", "'":
                _ = lexString()
            case "#":
                skipLine()
            case "[", "{":
                closers.append(scalar == "[" ? "]" : "}")
                offset += 1
            case "]", "}":
                offset += 1
                if scalar == closers.last {
                    closers.removeLast()
                    if closers.isEmpty { return true }
                }
            default:
                offset += 1
            }
        }
        return false
    }

    private mutating func lexString(allowMultiline: Bool = true) -> StringToken? {
        guard let delimiter = current, delimiter == "\"" || delimiter == "'" else { return nil }
        offset += 1
        let multiline = allowMultiline && consume(delimiter == "\"" ? "\"\"" : "''")
        let start = offset
        while let scalar = current {
            if !multiline && scalar == "\n" { return nil }
            if scalar == delimiter {
                let end = offset
                offset += 1
                if multiline {
                    while current == delimiter { offset += 1 }
                    if offset - end < 3 { continue }
                }
                return StringToken(delimiter: delimiter, multiline: multiline,
                                   content: start..<end, closingQuotes: offset - end)
            } else if delimiter == "\"", scalar == "\\" {
                offset += 1
                if let escaped = current, multiline || escaped != "\n" { offset += 1 }
            } else {
                offset += 1
            }
        }
        return nil
    }

    private func decodeValue(_ range: Range<Int>) -> TOMLValue? {
        var decoder = self
        decoder.offset = range.lowerBound
        if decoder.current == "\"" || decoder.current == "'" {
            guard let token = decoder.lexString() else { return nil }
            return decodeString(token).map(TOMLValue.string)
        }
        if decoder.consume("[") {
            var strings: [String] = []
            decoder.skipArrayWhitespace()
            if decoder.consume("]") { return .strings(strings) }
            while let token = decoder.lexString(), let value = decodeString(token) {
                strings.append(value)
                decoder.skipArrayWhitespace()
                if decoder.consume("]") { return .strings(strings) }
                guard decoder.consume(",") else { return nil }
                decoder.skipArrayWhitespace()
                if decoder.consume("]") { return .strings(strings) }
            }
            return nil
        }
        var end = range.upperBound
        while end > range.lowerBound, input[end - 1] == " " || input[end - 1] == "\t" { end -= 1 }
        let scalar = input[range.lowerBound..<end]
        if scalar.elementsEqual("true".unicodeScalars) { return .bool(true) }
        if scalar.elementsEqual("false".unicodeScalars) { return .bool(false) }
        return nil
    }

    private func decodeString(_ token: StringToken) -> String? {
        guard token.closingQuotes <= 5 else { return nil }
        var cursor = token.content.lowerBound
        let end = token.content.upperBound
        if token.multiline, cursor < end, input[cursor] == "\n" { cursor += 1 }
        var value = String.UnicodeScalarView()
        while cursor < end {
            let scalar = input[cursor]
            cursor += 1
            if token.delimiter == "\"", scalar == "\\" {
                if token.multiline {
                    var next = cursor
                    while next < end, input[next] == " " || input[next] == "\t" { next += 1 }
                    if next < end, input[next] == "\n" {
                        cursor = next + 1
                        while cursor < end, input[cursor] == " " || input[cursor] == "\t" || input[cursor] == "\n" {
                            cursor += 1
                        }
                        continue
                    }
                }
                guard let escaped = decodeEscape(at: &cursor, end: end) else { return nil }
                value.append(escaped)
            } else {
                guard (scalar.value >= 0x20 && scalar.value != 0x7F) || scalar == "\t"
                    || (token.multiline && scalar == "\n") else { return nil }
                value.append(scalar)
            }
        }
        if token.multiline {
            value.append(contentsOf: repeatElement(token.delimiter, count: token.closingQuotes - 3))
        }
        return String(value)
    }

    private func decodeEscape(at cursor: inout Int, end: Int) -> Unicode.Scalar? {
        guard cursor < end else { return nil }
        let scalar = input[cursor]
        cursor += 1
        switch scalar {
        case "\"", "\\": return scalar
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "n": return "\n"
        case "t": return "\t"
        case "u", "U":
            let count = scalar == "u" ? 4 : 8
            guard cursor + count <= end else { return nil }
            let digits = input[cursor..<cursor + count]
            guard digits.allSatisfy({
                ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
            }), let number = UInt32(String(String.UnicodeScalarView(digits)), radix: 16),
                let scalar = Unicode.Scalar(number)
            else { return nil }
            cursor += count
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
