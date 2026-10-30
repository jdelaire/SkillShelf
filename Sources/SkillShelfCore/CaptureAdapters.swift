import Darwin
import Foundation

public struct CaptureWorkingDirectory: Sendable {
    public let raw: String
    public let canonical: String

    init(path: String, id: UUID) throws {
        let name = "skillshelf-capture-" + id.uuidString
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let canonical = url.resolvingSymlinksInPath()
        guard path.hasPrefix("/"), url.lastPathComponent == name, canonical.lastPathComponent == name else {
            throw POSIXError(.EINVAL)
        }
        self.raw = path
        self.canonical = canonical.path
    }

    func claudeProjectPaths(home: String) -> [String] {
        guard home.hasPrefix("/") else { return [] }
        return Set([raw, canonical]).map { path in
            home + "/.claude/projects/" + path.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        }.sorted()
    }
}

public struct CaptureAdapter: Sendable {
    public let harness: HarnessID
    public let tool: String
    public let format: CaptureFormat
    public let unixSockets: [String]
    public let cleanupPaths: @Sendable (_ home: String, _ cwd: CaptureWorkingDirectory, _ sentinel: String) -> [String]
    public let launch: @Sendable (_ baseURL: String, _ sentinel: String) -> (arguments: [String], environment: [String: String])

    public init(
        harness: HarnessID, tool: String, format: CaptureFormat, unixSockets: [String],
        cleanupPaths: @escaping @Sendable (_ home: String, _ cwd: CaptureWorkingDirectory, _ sentinel: String) -> [String] = { _, _, _ in [] },
        launch: @escaping @Sendable (_ baseURL: String, _ sentinel: String) -> (arguments: [String], environment: [String: String])
    ) {
        self.harness = harness
        self.tool = tool
        self.format = format
        self.unixSockets = unixSockets
        self.cleanupPaths = cleanupPaths
        self.launch = launch
    }
}

public enum CaptureAdapters {
    public static let placeholder = "skillshelf-placeholder"

    public static func adapter(for harness: HarnessID) -> CaptureAdapter? {
        switch harness {
        case .claude:
            CaptureAdapter(
                harness: harness, tool: "claude", format: .anthropic, unixSockets: [], cleanupPaths: claudeProjectPaths
            ) { baseURL, sentinel in
                (["-p", "--no-session-persistence", sentinel], ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_API_KEY": placeholder])
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
                    "exec", "--ephemeral", "--skip-git-repo-check", sentinel
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
                return (["run", sentinel], ["OPENCODE_CONFIG_CONTENT": String(decoding: data, as: UTF8.self), "OPENCODE_DB": ":memory:"])
            }
        case .grok, .muse, .cursor, .antigravity:
            nil
        }
    }

    private static func claudeProjectPaths(home: String, cwd: CaptureWorkingDirectory, sentinel: String) -> [String] {
        cwd.claudeProjectPaths(home: home)
    }

    public static func unavailableReason(for harness: HarnessID) -> String? {
        switch harness {
        case .grok: "Requires real login"
        case .muse: "Placeholder key needs --api-key-stdin, not supported yet"
        case .cursor: "Prompt is assembled on Cursor's servers"
        case .antigravity: "No verified local redirect"
        case .claude, .codex, .opencode: nil
        }
    }
}

public enum DiagnosticNotes {
    public static func mcpFailures(_ text: String) -> [String] {
        let pattern = #"(?i)\bmcp(?:\s+server\s+|\]\s*|:\s*)["'“]?([\w.-]+)["'”]?.*\b(fail|error|could not connect|unable)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            if let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                return "MCP server \(line[range]) failed"
            }
            guard line.range(of: #"(?i)\brmcp::.*\b(fatal|fail|error)"#, options: .regularExpression) != nil,
                  let range = line.range(of: #"https?://[^"'\s<>)]{1,}"#, options: .regularExpression),
                  let host = URL(string: String(line[range]))?.host else { return nil }
            return "MCP server \(host) failed"
        }
    }
}
