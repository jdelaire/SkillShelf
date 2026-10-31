import Darwin
import Foundation

public actor PromptCapture {
    private let launcher: any CaptureProcessLaunching
    private let resolveTool: @Sendable (String) async -> String?
    private let loginEnvironment: @Sendable () async -> [String: String]
    private let capturesRoot: String
    private let tempRoot: String
    private let timeout: Duration
    private var isRunning = false

    public init(
        launcher: any CaptureProcessLaunching = SpawnLauncher(),
        resolveTool: @escaping @Sendable (String) async -> String?,
        loginEnvironment: @escaping @Sendable () async -> [String: String],
        capturesRoot: String = NSHomeDirectory() + "/Library/Application Support/SkillShelf/captures",
        tempRoot: String = NSTemporaryDirectory(), timeout: Duration = .seconds(60)
    ) {
        self.launcher = launcher
        self.resolveTool = resolveTool
        self.loginEnvironment = loginEnvironment
        self.capturesRoot = capturesRoot
        self.tempRoot = tempRoot
        self.timeout = timeout
    }

    public func run(_ adapter: CaptureAdapter, version: String?) async throws -> String {
        guard !isRunning else { throw CaptureError.busy }
        isRunning = true
        defer { isRunning = false }
        let sentinel = "SKILLSHELF_CAPTURE_" + UUID().uuidString
        let listener = CaptureListener(format: adapter.format)
        let directoryID = UUID()
        let directory = URL(fileURLWithPath: tempRoot, isDirectory: true)
            .appendingPathComponent("skillshelf-capture-" + directoryID.uuidString).path
        let stop = AsyncStream<Void>.makeStream()
        return try await withTaskCancellationHandler {
            var process: (any CaptureProcessHandle)?
            var workingDirectory: CaptureWorkingDirectory?
            var home = NSHomeDirectory()
            do {
                try Task.checkCancellation()
                let executable = await resolveTool(adapter.tool)
                try Task.checkCancellation()
                guard let executable else { throw CaptureError.notInstalled }
                let port = try await listener.start()
                try Task.checkCancellation()
                try await CaptureSandbox.verify(port: port, unixSockets: adapter.unixSockets)
                try Task.checkCancellation()
                var environment = CaptureEnvironment.sanitized(await loginEnvironment())
                home = environment["HOME"] ?? NSHomeDirectory()
                try Task.checkCancellation()
                let launch = adapter.launch("http://127.0.0.1:\(port)", sentinel)
                environment.merge(launch.environment) { _, adapterValue in adapterValue }
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
                workingDirectory = try CaptureWorkingDirectory(path: directory, id: directoryID)
                let command = [executable] + launch.arguments
                let argv = try CaptureSandbox.wrap(command, port: port, unixSockets: adapter.unixSockets)
                try Task.checkCancellation()
                let handle = try launcher.launch(argv: argv, environment: environment, cwd: directory)
                process = handle
                let requests = await collect(listener: listener, process: handle, sentinel: sentinel, stop: stop)
                let cleanupNotes = try await cleanUp(
                    process: handle, listener: listener, directory: directory, workingDirectory: workingDirectory,
                    adapter: adapter, home: home, sentinel: sentinel
                )
                process = nil
                try Task.checkCancellation()
                guard !requests.isEmpty else { throw CaptureError.noRequest(version: version) }
                let diagnostics = await handle.diagnostics()
                let notes = ["sentinel: \(sentinel)", "Placeholder auth: account-specific text may differ"]
                    + cleanupNotes
                    + listener.notes()
                    + DiagnosticNotes.mcpFailures(diagnostics.stdout)
                    + DiagnosticNotes.mcpFailures(diagnostics.stderr)
                let tail = diagnostics.stderr.utf8.suffix(4096).drop(while: { $0 & 0xc0 == 0x80 })
                let record = CaptureRecord(
                    harness: adapter.harness.rawValue, version: version, adapter: adapter.tool,
                    command: command.map { $0.replacingOccurrences(of: CaptureAdapters.placeholder, with: "<placeholder>") },
                    date: Date(), notes: notes, requests: requests,
                    diagnostics: tail.isEmpty ? nil : String(decoding: tail, as: UTF8.self)
                )
                try Task.checkCancellation()
                return try record.save(to: URL(fileURLWithPath: capturesRoot, isDirectory: true)
                    .appendingPathComponent(adapter.harness.rawValue).path)
            } catch {
                _ = try await cleanUp(
                    process: process, listener: listener, directory: directory, workingDirectory: workingDirectory,
                    adapter: adapter, home: home, sentinel: sentinel
                )
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            stop.continuation.finish()
        }
    }

    private func collect(
        listener: CaptureListener, process: any CaptureProcessHandle, sentinel: String,
        stop: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)
    ) async -> [CapturedRequest] {
        let reader = Task {
            var requests: [CapturedRequest] = []
            for await request in listener.requests {
                requests.append(request)
                if request.body.contains(sentinel), CaptureParser.hasTools(request.body) {
                    stop.continuation.yield(())
                }
            }
            stop.continuation.yield(())
            return requests
        }
        let exit = Task {
            _ = await process.exitStatus()
            stop.continuation.yield(())
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                stop.continuation.yield(())
            } catch {}
        }
        var iterator = stop.stream.makeAsyncIterator()
        _ = await iterator.next()
        await process.terminate()
        _ = await process.exitStatus()
        await listener.stop()
        let requests = await reader.value
        timer.cancel()
        await timer.value
        await exit.value
        stop.continuation.finish()
        return requests
    }

    private func cleanUp(
        process: (any CaptureProcessHandle)?, listener: CaptureListener, directory: String,
        workingDirectory: CaptureWorkingDirectory?, adapter: CaptureAdapter, home: String, sentinel: String
    ) async throws -> [String] {
        if let process {
            await process.terminate()
            _ = await process.exitStatus()
        }
        await listener.stop()
        let sessionCleanup = Result<[String], Error> {
            guard process != nil, let workingDirectory else { return [] }
            let allowed = adapter.harness == .claude ? Set(workingDirectory.claudeProjectPaths(home: home)) : []
            let paths = adapter.cleanupPaths(home, workingDirectory, sentinel).filter { allowed.contains($0) }
            guard !paths.isEmpty else { return [] }
            let projects: CaptureArtifactDirectory?
            do {
                projects = try CaptureArtifactDirectory(home: home)
            } catch {
                return ["Session artifact cleanup skipped: .claude/projects could not be opened safely. \(error.localizedDescription)"]
            }
            guard let projects else { return [] }
            for path in paths {
                try projects.removeProject(named: URL(fileURLWithPath: path).lastPathComponent)
            }
            return []
        }
        try removeWithoutFollowingSymlink(directory)
        return try sessionCleanup.get()
    }

    private func removeWithoutFollowingSymlink(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
