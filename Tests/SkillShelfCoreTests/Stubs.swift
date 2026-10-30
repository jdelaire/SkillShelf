import Foundation
@testable import SkillShelfCore

struct StubRunner: CommandRunning {
    let result: CommandResult

    init(output: String, error: String = "", status: Int32 = 0) {
        result = CommandResult(status: status, output: output, error: error)
    }

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        result
    }
}

struct FailingFetcher: PromptFetching {
    func data(from url: URL) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

actor CountingFetcher: PromptFetching {
    private(set) var count = 0

    func data(from url: URL) async throws -> Data {
        count += 1
        return Data()
    }
}

actor StubFetcher: PromptFetching {
    let response: Data
    private(set) var urls: [URL] = []

    init(_ response: String) {
        self.response = Data(response.utf8)
    }

    func data(from url: URL) async throws -> Data {
        urls.append(url)
        return response
    }
}

actor RecordingRunner: CommandRunning {
    private(set) var calls: [(String, [String])] = []

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append((tool, arguments))
        return CommandResult(status: 0, output: "1.2.3", error: "")
    }
}

struct ThrowingRunner: CommandRunning {
    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        throw CommandError.toolNotFound(tool)
    }
}
