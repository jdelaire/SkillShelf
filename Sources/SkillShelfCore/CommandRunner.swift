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
        guard let executable = await resolve(tool) else { throw CommandError.toolNotFound(tool) }
        let environment = await loginEnvironment()
        let result = try await Self.launch(executable, arguments, environment, home, timeout)
        if result.timedOut { throw CommandError.timedOut(tool) }
        return CommandResult(status: result.status, output: result.output, error: result.error)
    }

    public func resolve(_ tool: String) async -> String? {
        guard let path = try? await resolvedPath() else { return nil }
        return path.split(separator: ":").map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func loginEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let path = try? await resolvedPath() { environment["PATH"] = path }
        return environment
    }

    private func resolvedPath() async throws -> String {
        if let loginPath { return loginPath }
        let result = try await Self.launch(
            "/bin/zsh", ["-lc", "print -r -- $PATH"], ProcessInfo.processInfo.environment, home, .seconds(30)
        )
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        loginPath = path
        return path
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        var timedOut = false
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var ended = false

        init(_ handle: FileHandle) {
            handle.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                lock.withLock {
                    if chunk.isEmpty {
                        ended = true
                        handle.readabilityHandler = nil
                    } else {
                        data.append(chunk)
                    }
                }
            }
        }

        var isEnded: Bool { lock.withLock { ended } }

        func finish(_ handle: FileHandle) -> Data {
            handle.readabilityHandler = nil
            return lock.withLock { data }
        }
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
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        let outCollector = Collector(outHandle)
        let errCollector = Collector(errHandle)
        try process.run()
        let pid = process.processIdentifier
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            box.timedOut = true
            box.process.terminate()
            try await Task.sleep(for: .seconds(2))
            kill(pid, SIGKILL)
        }
        var status: Int32 = -1
        for await code in exits { status = code }
        watchdog.cancel()
        let drainDeadline = ContinuousClock.now + .seconds(2)
        while !(outCollector.isEnded && errCollector.isEnded), ContinuousClock.now < drainDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let output = String(decoding: outCollector.finish(outHandle), as: UTF8.self)
        let error = String(decoding: errCollector.finish(errHandle), as: UTF8.self)
        return (status, output, error, box.timedOut)
    }
}
