import Darwin
import Foundation
import Synchronization
import Testing
@testable import SkillShelfCore

struct PromptCaptureTests {
    @Test func claudeAdapterBuildsPlaceholderLaunch() throws {
        let adapter = try #require(CaptureAdapters.adapter(for: .claude))
        let launch = adapter.launch("http://127.0.0.1:9", "S")
        #expect(launch.arguments == ["-p", "S"])
        #expect(launch.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9")
        #expect(launch.environment["ANTHROPIC_API_KEY"] == "skillshelf-placeholder")
    }

    @Test func codexAdapterRedirectsResponsesWithWebSocketsDisabled() throws {
        let adapter = try #require(CaptureAdapters.adapter(for: .codex))
        let launch = adapter.launch("http://127.0.0.1:9", "S")
        #expect(launch.arguments.suffix(3) == ["exec", "--skip-git-repo-check", "S"])
        #expect(launch.arguments.contains("model_provider=skillshelf"))
        #expect(launch.arguments.contains("model_providers.skillshelf.base_url=\"http://127.0.0.1:9/v1\""))
        #expect(launch.arguments.contains("model_providers.skillshelf.wire_api=\"responses\""))
        #expect(launch.arguments.contains("model_providers.skillshelf.env_key=\"SKILLSHELF_API_KEY\""))
        #expect(launch.arguments.contains("model_providers.skillshelf.supports_websockets=false"))
        #expect(launch.environment["SKILLSHELF_API_KEY"] == "skillshelf-placeholder")
    }

    @Test func opencodeAdapterSelectsPlaceholderProvider() throws {
        let adapter = try #require(CaptureAdapters.adapter(for: .opencode))
        let launch = adapter.launch("http://127.0.0.1:9", "S")
        #expect(launch.arguments == ["run", "S"])
        let text = try #require(launch.environment["OPENCODE_CONFIG_CONTENT"])
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let providers = try #require(config["provider"] as? [String: Any])
        let provider = try #require(providers["skillshelf"] as? [String: Any])
        let options = try #require(provider["options"] as? [String: String])
        #expect(options["baseURL"] == "http://127.0.0.1:9/v1")
        #expect(options["apiKey"] == "skillshelf-placeholder")
        #expect((config["model"] as? String)?.hasPrefix("skillshelf/") == true)
    }

    @Test func unavailableAdaptersExplainWhy() {
        for harness in [HarnessID.grok, .muse] {
            #expect(CaptureAdapters.adapter(for: harness) == nil)
            #expect(CaptureAdapters.unavailableReason(for: harness) == "Requires real login")
        }
        #expect(CaptureAdapters.adapter(for: .cursor) == nil)
        #expect(CaptureAdapters.unavailableReason(for: .cursor) == "Prompt is assembled on Cursor's servers")
        #expect(CaptureAdapters.adapter(for: .antigravity) == nil)
        #expect(CaptureAdapters.unavailableReason(for: .antigravity) == "No verified local redirect")
        #expect(CaptureAdapters.unavailableReason(for: .claude) == nil)
    }

    @Test func mcpFailureLinesBecomeNotes() {
        #expect(DiagnosticNotes.mcpFailures("MCP server \"github\" failed to connect\nok\n[mcp] linear: error: ECONNREFUSED") == [
            "MCP server github failed", "MCP server linear failed"
        ])
        #expect(DiagnosticNotes.mcpFailures("mcp server 'a.b-c' unable to start\nMCP server “remote” could not connect\nMCP server ok connected\nordinary error") == [
            "MCP server a.b-c failed", "MCP server remote failed"
        ])
    }

    @Test func captureStopsOnSentinelRequestAndCleansUp() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, """
        echo 'MCP server "remote" failed to connect' >&2
        echo '[mcp] local: error: unavailable'
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/v1/messages" -d "{\\"tools\\":[{\\"name\\":\\"a\\"}],\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"$1\\"}]}"
        sleep 60
        """)
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher)
        let start = ContinuousClock.now
        let path = try await capture.run(adapter(), version: "1.0")
        #expect(ContinuousClock.now - start < .seconds(10))
        let record = try CaptureRecord.load(path)
        #expect(record.requests.count == 1)
        #expect(record.notes.contains("MCP server remote failed"))
        #expect(record.notes.contains("MCP server local failed"))
        #expect(record.notes.contains("Placeholder auth: account-specific text may differ"))
        let sentinel = try #require(record.notes.first { $0.hasPrefix("sentinel: ") })
        #expect(sentinel.hasPrefix("sentinel: SKILLSHELF_CAPTURE_"))
        #expect(CaptureParser.mainRequest(record.requests, sentinel: String(sentinel.dropFirst(10))) == .found(0))
        #expect(!(try String(contentsOfFile: path, encoding: .utf8)).localizedCaseInsensitiveContains("user-agent"))
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: dir.path + "/captures/claude")[.posixPermissions] as? Int == 0o700)
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func secondCaptureWhileBusyThrows() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, "echo ready > \"$MARKER\"\nsleep 60")
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher)
        let task = Task { try await capture.run(adapter(marker: dir.path + "/ready"), version: "1.0") }
        do {
            try await waitForFile(dir.path + "/ready", timeout: .seconds(10))
            await #expect(throws: CaptureError.busy) { try await capture.run(adapter(), version: "1.0") }
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func noRequestTimesOutWithMessage() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, "echo ready > \"$MARKER\"\nsleep 60")
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher, timeout: .seconds(2))
        let start = ContinuousClock.now
        await #expect(throws: CaptureError.noRequest(version: "1.0")) {
            try await capture.run(adapter(marker: dir.path + "/ready"), version: "1.0")
        }
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(FileManager.default.fileExists(atPath: dir.path + "/ready"))
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func cancellationCleansUp() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, "echo ready > \"$MARKER\"\nsleep 60")
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher)
        let task = Task { try await capture.run(adapter(marker: dir.path + "/ready"), version: nil) }
        do {
            try await waitForFile(dir.path + "/ready", timeout: .seconds(10))
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try expectCleanup(dir, launcher: launcher)
        #expect(!FileManager.default.fileExists(atPath: dir.path + "/captures/claude"))
    }

    @Test func missingToolThrowsNotInstalled() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: nil, launcher: launcher)
        await #expect(throws: CaptureError.notInstalled) { try await capture.run(adapter(), version: nil) }
        #expect(launcher.pids.isEmpty)
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func freshEmptyCwdAndSanitizedEnvironmentForEveryCapture() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, """
        /bin/pwd >> "$CWD_LOG"
        test -z "$(/bin/ls -A)" || exit 3
        test -z "$ANTHROPIC_AUTH_TOKEN$OPENAI_API_KEY$https_proxy" || exit 4
        test "$ANTHROPIC_API_KEY" = skillshelf-placeholder || exit 5
        touch local-file
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/v1/messages" -d "{\\"tools\\":[{}],\\"input\\":\\"$1\\"}"
        """)
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher, environment: [
            "PATH": "/usr/bin:/bin", "HOME": dir.path, "ANTHROPIC_AUTH_TOKEN": "real",
            "OPENAI_API_KEY": "real", "https_proxy": "http://127.0.0.1:1"
        ])
        let adapter = CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: []) { base, sentinel in
            ([sentinel], ["BASE": base, "CWD_LOG": dir.path + "/cwds", "ANTHROPIC_API_KEY": "skillshelf-placeholder"])
        }
        _ = try await capture.run(adapter, version: nil)
        _ = try await capture.run(adapter, version: nil)
        let cwds = try String(contentsOfFile: dir.path + "/cwds", encoding: .utf8).split(separator: "\n")
        #expect(cwds.count == 2)
        #expect(Set(cwds).count == 2)
        #expect(cwds.allSatisfy { $0.hasPrefix(dir.path + "/tmp/skillshelf-capture-") })
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func processExitPreservesHelpersAndBestGuessWithoutWaitingForTimeout() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, """
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/helper" -d '{"tools":[{}],"input":"helper"}'
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/main" -d "{\\"input\\":\\"$1\\"}"
        """)
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher)
        let start = ContinuousClock.now
        let record = try CaptureRecord.load(try await capture.run(adapter(), version: nil))
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(record.requests.map(\.path) == ["/helper", "/main"])
        let note = try #require(record.notes.first { $0.hasPrefix("sentinel: ") })
        #expect(CaptureParser.mainRequest(record.requests, sentinel: String(note.dropFirst(10))) == .bestGuess(1))
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func savedCommandRedactsPlaceholderAndDiagnosticsKeepLastFourKB() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, """
        /usr/bin/printf '%05000d' 0 >&2
        echo stderr-tail >&2
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/main" -d "{\\"tools\\":[{}],\\"input\\":\\"$1\\"}"
        sleep 60
        """)
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher)
        let adapter = CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: []) { base, sentinel in
            ([sentinel, "--key=skillshelf-placeholder"], ["BASE": base])
        }
        let record = try CaptureRecord.load(try await capture.run(adapter, version: nil))
        #expect(record.command.contains("--key=<placeholder>"))
        #expect(record.command.allSatisfy { !$0.contains("skillshelf-placeholder") })
        let diagnostics = try #require(record.diagnostics)
        #expect(diagnostics.utf8.count == 4096)
        #expect(diagnostics.hasSuffix("stderr-tail\n"))
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func launchFailureClosesListenerAndRemovesCwd() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: "/bin/sh", launcher: launcher)
        let adapter = CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: []) { base, _ in
            (["-c", "exit 0"], ["BASE": base, "INVALID": "\0"])
        }
        await #expect(throws: POSIXError(.EINVAL)) { try await capture.run(adapter, version: nil) }
        #expect(launcher.pids.isEmpty)
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func cancellationDuringEnvironmentLookupNeverLaunchesAndResetsBusy() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let launcher = RecordingLauncher()
        let release = AsyncStream<Void>.makeStream()
        let capture = PromptCapture(
            launcher: launcher, resolveTool: { _ in "/bin/sh" }, loginEnvironment: {
                try? Data().write(to: URL(fileURLWithPath: dir.path + "/ready"))
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return ["PATH": "/usr/bin:/bin"]
            }, capturesRoot: dir.path + "/captures", tempRoot: dir.path + "/tmp"
        )
        let task = Task { try await capture.run(adapter(), version: nil) }
        do {
            try await waitForFile(dir.path + "/ready", timeout: .seconds(10))
            await #expect(throws: CaptureError.busy) { try await capture.run(adapter(), version: nil) }
        } catch {
            task.cancel()
            release.continuation.finish()
            _ = await task.result
            throw error
        }
        task.cancel()
        release.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(launcher.pids.isEmpty)
        let invalid = CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: ["bad\"path"]) { _, _ in
            ([], [:])
        }
        await #expect(throws: CaptureError.sandboxUnavailable) { try await capture.run(invalid, version: nil) }
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func stopsOnlyWhenSentinelAndToolsShareRequestAndKeepsListenerNotes() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let script = try script(dir, """
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/upgrade" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -d '{}'
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/helper" -d '{"tools":[{}],"input":"helper"}'
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/guess" -d "{\\"tools\\":[],\\"input\\":\\"$1\\"}"
        /usr/bin/curl --noproxy '*' -s -X POST "$BASE/main" -d "{\\"tools\\":[{}],\\"input\\":\\"$1\\"}"
        sleep 60
        """)
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: script, launcher: launcher)
        let record = try CaptureRecord.load(try await capture.run(adapter(), version: nil))
        #expect(record.requests.map(\.path) == ["/helper", "/guess", "/main"])
        #expect(record.notes.contains("WebSocket upgrade refused"))
        let note = try #require(record.notes.first { $0.hasPrefix("sentinel: ") })
        #expect(CaptureParser.mainRequest(record.requests, sentinel: String(note.dropFirst(10))) == .found(2))
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func invalidSandboxNeverLaunchesHarness() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let launcher = RecordingLauncher()
        let capture = capture(dir, script: "/bin/sh", launcher: launcher)
        let adapter = CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: ["bad\"path"]) { _, _ in
            (["-c", "exit 0"], [:])
        }
        await #expect(throws: CaptureError.sandboxUnavailable) { try await capture.run(adapter, version: nil) }
        #expect(launcher.pids.isEmpty)
        try expectCleanup(dir, launcher: launcher)
    }

    @Test func loginRunnerResolvesSh() async {
        #expect(await LoginShellRunner().resolve("sh") == "/bin/sh")
    }

    @Test func loginEnvironmentUsesLoginPath() async throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let runner = LoginShellRunner(home: dir.path)
        let environment = await runner.loginEnvironment()
        let path = try #require(environment["PATH"])
        #expect(!path.isEmpty)
        #expect(path.split(separator: ":").contains("/bin"))
        #expect(environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
        #expect(await runner.resolve("skillshelf-missing-" + UUID().uuidString) == nil)
    }

    private func script(_ dir: TempDir, _ body: String) throws -> String {
        let path = dir.path + "/fake.sh"
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    private func adapter(marker: String = "") -> CaptureAdapter {
        CaptureAdapter(harness: .claude, tool: "fake.sh", format: .anthropic, unixSockets: []) { base, sentinel in
            ([sentinel], ["BASE": base, "MARKER": marker])
        }
    }

    private func capture(
        _ dir: TempDir, script: String?, launcher: RecordingLauncher, timeout: Duration = .seconds(60),
        environment: [String: String] = ["PATH": "/usr/bin:/bin"]
    ) -> PromptCapture {
        PromptCapture(
            launcher: launcher, resolveTool: { _ in script }, loginEnvironment: { environment },
            capturesRoot: dir.path + "/captures", tempRoot: dir.path + "/tmp", timeout: timeout
        )
    }

    private func expectCleanup(_ dir: TempDir, launcher: RecordingLauncher) throws {
        if FileManager.default.fileExists(atPath: dir.path + "/tmp") {
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path + "/tmp").isEmpty)
        }
        #expect(launcher.pids.allSatisfy { kill(-$0, 0) == -1 })
        for port in launcher.ports {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            #expect(result == -1 && errno == ECONNREFUSED)
        }
    }
}

private final class RecordingLauncher: CaptureProcessLaunching {
    private let state = Mutex((pids: [pid_t](), ports: [UInt16]()))

    var pids: [pid_t] { state.withLock { $0.pids } }
    var ports: [UInt16] { state.withLock { $0.ports } }

    func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle {
        if let base = environment["BASE"], let port = URL(string: base)?.port {
            state.withLock { $0.ports.append(UInt16(port)) }
        }
        let handle = try SpawnLauncher().launch(argv: argv, environment: environment, cwd: cwd)
        state.withLock { $0.pids.append(handle.pid) }
        return handle
    }
}
