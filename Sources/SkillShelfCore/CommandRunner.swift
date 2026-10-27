import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

public enum CommandError: Error, LocalizedError {
    case toolNotFound(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): "\(tool) is not on your login PATH."
        case .timedOut(let tool): "\(tool) did not finish within 120 seconds."
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult
}

public actor LoginShellRunner: CommandRunning {
    private let home: String
    private let timeout: Duration
    private var loginPath: String?

    public init(home: String = NSHomeDirectory(), timeout: Duration = .seconds(120)) {
        self.home = home
        self.timeout = timeout
    }

    public func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        let path = try await resolvedPath()
        guard let executable = path.split(separator: ":").map({ "\($0)/\(tool)" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw CommandError.toolNotFound(tool) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let result = try await Self.launch(executable, arguments, environment, home, timeout)
        if result.timedOut { throw CommandError.timedOut(tool) }
        return CommandResult(status: result.status, output: result.output, error: result.error)
    }

    private func resolvedPath() async throws -> String {
        if let loginPath { return loginPath }
        let result = try await Self.launch(
            "/bin/zsh", ["-lc", "print -r -- $PATH"], ProcessInfo.processInfo.environment, home, timeout
        )
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        loginPath = path
        return path
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        var timedOut = false
    }

    @concurrent
    private static func launch(
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ cwd: String,
        _ timeout: Duration
    ) async throws -> (status: Int32, output: String, error: String, timedOut: Bool) {
        let box = Box()
        let process = box.process
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let (exits, continuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        try process.run()
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        async let outData = readAll(outHandle)
        async let errData = readAll(errHandle)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            box.timedOut = true
            box.process.terminate()
        }
        var status: Int32 = -1
        for await code in exits { status = code }
        watchdog.cancel()
        let output = String(decoding: await outData, as: UTF8.self)
        let error = String(decoding: await errData, as: UTF8.self)
        return (status, output, error, box.timedOut)
    }

    @concurrent
    private static func readAll(_ handle: FileHandle) async -> Data {
        handle.readDataToEndOfFile()
    }
}
