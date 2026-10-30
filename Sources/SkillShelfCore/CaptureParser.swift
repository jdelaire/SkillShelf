import Foundation

public enum MainRequest: Sendable, Equatable {
    case found(Int)
    case bestGuess(Int)
    case unknown
}

public struct CaptureSections: Sendable {
    public var system: [String]
    public var tools: [(name: String, summary: String)]
    public var toolsJSON: String?
    public var messages: [(role: String, text: String)]
    public var raw: String?

    public init(
        system: [String] = [], tools: [(name: String, summary: String)] = [], toolsJSON: String? = nil,
        messages: [(role: String, text: String)] = [], raw: String? = nil
    ) {
        self.system = system
        self.tools = tools
        self.toolsJSON = toolsJSON
        self.messages = messages
        self.raw = raw
    }
}

public enum CaptureParser {
    public static func mainRequest(_ requests: [CapturedRequest], sentinel: String) -> MainRequest {
        var bestGuess: Int?
        for (index, request) in requests.enumerated() where request.body.contains(sentinel) {
            if hasTools(request.body) { return .found(index) }
            if bestGuess == nil { bestGuess = index }
        }
        return bestGuess.map(MainRequest.bestGuess) ?? .unknown
    }

    public static func sections(_ body: String) -> CaptureSections {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: .fragmentsAllowed) else {
            return CaptureSections(raw: body)
        }
        guard let object = json as? [String: Any] else {
            return CaptureSections(raw: prettyJSON(json) ?? body)
        }

        var result = CaptureSections()
        if object["messages"] is [Any] || object["system"] is String || object["system"] is [Any] {
            result.system = textBlocks(object["system"])
            result.messages = messages(object["messages"])
        } else if object["input"] is [Any] || object["input"] is String || object["instructions"] is String {
            result.system = textBlocks(object["instructions"])
            if let input = object["input"] as? String {
                result.messages = [(role: "user", text: input)]
            } else {
                result.messages = messages(object["input"])
            }
        } else {
            return CaptureSections(raw: prettyJSON(json) ?? body)
        }

        if let tools = object["tools"] as? [Any] {
            result.toolsJSON = prettyJSON(tools)
            result.tools = tools.compactMap { item in
                guard let tool = item as? [String: Any], let name = tool["name"] as? String else { return nil }
                let description = tool["description"] as? String ?? ""
                return (name: name, summary: String(description.prefix { !$0.isNewline }))
            }
        }
        return result
    }

    public static func hasTools(_ body: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let tools = object["tools"] as? [Any] else { return false }
        return !tools.isEmpty
    }

    private static func textBlocks(_ content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [Any] else { return [] }
        return blocks.compactMap { ($0 as? [String: Any])?["text"] as? String }
    }

    private static func messages(_ content: Any?) -> [(role: String, text: String)] {
        guard let items = content as? [Any] else { return [] }
        return items.compactMap { item in
            guard let message = item as? [String: Any], let role = message["role"] as? String else { return nil }
            return (role: role, text: textBlocks(message["content"]).joined(separator: "\n"))
        }
    }

    private static func prettyJSON(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
