import Foundation

public struct CaptureAdapter: Sendable {
    public let harness: HarnessID
    public let tool: String
    public let format: CaptureFormat
    public let unixSockets: [String]
    public let launch: @Sendable (_ baseURL: String, _ sentinel: String) -> (arguments: [String], environment: [String: String])

    public init(
        harness: HarnessID, tool: String, format: CaptureFormat, unixSockets: [String],
        launch: @escaping @Sendable (_ baseURL: String, _ sentinel: String) -> (arguments: [String], environment: [String: String])
    ) {
        self.harness = harness
        self.tool = tool
        self.format = format
        self.unixSockets = unixSockets
        self.launch = launch
    }
}

public enum CaptureAdapters {
    public static let placeholder = "skillshelf-placeholder"

    public static func adapter(for harness: HarnessID) -> CaptureAdapter? {
        switch harness {
        case .claude:
            CaptureAdapter(harness: harness, tool: "claude", format: .anthropic, unixSockets: []) { baseURL, sentinel in
                (["-p", sentinel], ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_API_KEY": placeholder])
            }
        case .codex:
            CaptureAdapter(harness: harness, tool: "codex", format: .openAI, unixSockets: []) { baseURL, sentinel in
                ([
                    "-c", "model_provider=skillshelf",
                    "-c", "model_providers.skillshelf.name=\"SkillShelf\"",
                    "-c", "model_providers.skillshelf.base_url=\"\(baseURL)/v1\"",
                    "-c", "model_providers.skillshelf.wire_api=\"responses\"",
                    "-c", "model_providers.skillshelf.env_key=\"SKILLSHELF_API_KEY\"",
                    "-c", "model_providers.skillshelf.supports_websockets=false",
                    "exec", "--skip-git-repo-check", sentinel
                ], ["SKILLSHELF_API_KEY": placeholder])
            }
        case .opencode:
            CaptureAdapter(harness: harness, tool: "opencode", format: .openAI, unixSockets: []) { baseURL, sentinel in
                let config: [String: Any] = [
                    "model": "skillshelf/capture",
                    "provider": ["skillshelf": [
                        "npm": "@ai-sdk/openai-compatible",
                        "name": "SkillShelf",
                        "options": ["baseURL": baseURL + "/v1", "apiKey": placeholder],
                        "models": ["capture": ["name": "Capture"]]
                    ]]
                ]
                let data = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                return (["run", sentinel], ["OPENCODE_CONFIG_CONTENT": String(decoding: data, as: UTF8.self)])
            }
        case .grok, .muse, .cursor, .antigravity:
            nil
        }
    }

    public static func unavailableReason(for harness: HarnessID) -> String? {
        switch harness {
        case .grok, .muse: "Requires real login"
        case .cursor: "Prompt is assembled on Cursor's servers"
        case .antigravity: "No verified local redirect"
        case .claude, .codex, .opencode: nil
        }
    }
}

public enum DiagnosticNotes {
    public static func mcpFailures(_ text: String) -> [String] {
        let pattern = #"(?i)mcp.*?\b(server\s+)?["'“]?([\w.-]+)["'”]?.*\b(fail|error|could not connect|unable)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 2), in: line) else { return nil }
            return "MCP server \(line[range]) failed"
        }
    }
}
