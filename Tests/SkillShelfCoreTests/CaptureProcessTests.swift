import Darwin
import Foundation
import Testing
@testable import SkillShelfCore

struct CaptureProcessTests {
    @Test func sanitizedEnvironmentDropsCredentialsAndProxies() {
        let base = [
            "PATH": "/bin", "HOME": "/h", "ANTHROPIC_API_KEY": "k", "https_proxy": "x",
            "OPENAI_BASE_URL": "u", "CLAUDE_CODE_OAUTH_TOKEN": "t", "gemini_api_key": "g",
            "Google_APPLICATION_CREDENTIALS": "g", "xai_api_key": "x", "http_proxy": "p",
            "ALL_PROXY": "p", "No_Proxy": "p", "anthropic_auth_token": "a", "openai_api_key": "o",
            "ANTHROPIC": "keep", "MY_OPENAI_KEY": "keep"
        ]
        #expect(CaptureEnvironment.sanitized(base) == [
            "PATH": "/bin", "HOME": "/h", "ANTHROPIC": "keep", "MY_OPENAI_KEY": "keep"
        ])
    }

    @Test func sandboxAllowsOnlyCapturePortForCurlAndDescendants() async throws {
        try await withListener(.openAI) { _, port in
            try await withListener(.openAI) { _, other in
                let curl = { (port: UInt16) in
                    "/usr/bin/curl --noproxy '*' --max-time 5 -vsS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:\(port)/x 2>&1"
                }
                try await CaptureSandbox.verify(port: port, unixSockets: [])
                #expect(try runShell(curl(other)).hasSuffix("400"))
                #expect(try runShell(curl(port), sandboxPort: port).hasSuffix("400"))
                let denied = try runShell(curl(other), sandboxPort: port)
                #expect(denied.contains("Operation not permitted"))
                let descendant = "/bin/sh -c \"\(curl(other))\""
                #expect(try runShell(descendant).hasSuffix("400"))
                let deniedDescendant = try runShell(descendant, sandboxPort: port)
                #expect(deniedDescendant.contains("Operation not permitted"))
            }
        }
    }

    @Test func sandboxBlocksNonLoopbackAndUnixSockets() throws {
        let address = try #require(LocalAddresses.nonLoopbackIPv4().first, "needs a non-loopback interface")
        let tcp = try TestTCPServer(bind: "0.0.0.0")
        defer { tcp.close() }
        let remote = "/usr/bin/nc -z -v -G 1 \(address) \(tcp.port) 2>&1; echo $?"
        #expect(try runShell(remote).hasSuffix("0"))
        #expect(try runShell(remote, sandboxPort: 9).contains("Operation not permitted"))
        let unix = try TestUnixServer()
        defer { unix.close() }
        let curlUnix = { (path: String) in
            "/usr/bin/curl --noproxy '*' --max-time 5 -vsS -o /dev/null -w '%{http_code}' --unix-socket '\(path)' http://localhost/x 2>&1"
        }
        let local = curlUnix(unix.path)
        let unixControl = try runShell(local)
        let unixDenied = try runShell(local, sandboxPort: 9)
        #expect(unixControl.hasSuffix("200"))
        #expect(unixDenied.contains("Operation not permitted"))
        let allowedUnix = try runShell(local, sandboxPort: 9, unixSockets: [unix.path])
        #expect(allowedUnix.hasSuffix("200"))
        let other = try TestUnixServer()
        defer { other.close() }
        let otherCommand = curlUnix(other.path)
        #expect(try runShell(otherCommand).hasSuffix("200"))
        #expect(try runShell(otherCommand, sandboxPort: 9, unixSockets: [unix.path]).contains("Operation not permitted"))
    }

    @Test func sandboxCoversURLSessionClients() async throws {
        try await withListener(.openAI) { _, port in
            try await withListener(.openAI) { _, other in
                #expect(try runProbe("http://127.0.0.1:\(port)/x", sandboxPort: port) == "400")
                #expect(try runProbe("http://127.0.0.1:\(other)/x") == "400")
                let denied = try runProbe("http://127.0.0.1:\(other)/x", sandboxPort: port)
                #expect(denied.hasPrefix("error "))
                #expect(denied.hasSuffix(" 1"))
            }
        }
    }

    @Test(arguments: ["\")(allow", "/tmp/a\\b", "/tmp/a\nb"])
    func invalidProfileFailsVerify(path: String) async {
        #expect(throws: CaptureError.sandboxUnavailable) {
            try CaptureSandbox.wrap(["/usr/bin/true"], port: 1, unixSockets: [path])
        }
        await #expect(throws: CaptureError.sandboxUnavailable) {
            try await CaptureSandbox.verify(port: 1, unixSockets: [path])
        }
    }

    @Test func terminateKillsWholeProcessGroup() async throws {
        let directory = try TempDir()
        defer { directory.remove() }
        let handle = try SpawnLauncher().launch(
            argv: ["/bin/sh", "-c", "sleep 60 & echo $! > child; sleep 60"],
            environment: ["PATH": "/bin:/usr/bin"], cwd: directory.path
        )
        do {
            try await waitForFile(directory.path + "/child", timeout: .seconds(5))
            await handle.terminate()
            #expect(kill(-handle.pid, 0) == -1 && errno == ESRCH)
        } catch {
            await handle.terminate()
            throw error
        }
    }

    @Test func terminateEscalatesForResistantDescendantAfterLeaderExits() async throws {
        let directory = try TempDir()
        defer { directory.remove() }
        let handle = try SpawnLauncher().launch(
            argv: ["/bin/sh", "-c", "(trap '' TERM; echo ready > child; while :; do sleep 1; done) & exit 0"],
            environment: ["PATH": "/bin:/usr/bin"], cwd: directory.path
        )
        do {
            try await waitForFile(directory.path + "/child", timeout: .seconds(5))
            #expect(await handle.exitStatus() == 0)
            let start = ContinuousClock.now
            async let first: Void = handle.terminate()
            async let second: Void = handle.terminate()
            _ = await (first, second)
            #expect(ContinuousClock.now - start >= .seconds(3))
            #expect(ContinuousClock.now - start < .seconds(8))
            #expect(kill(-handle.pid, 0) == -1 && errno == ESRCH)
        } catch {
            await handle.terminate()
            throw error
        }
    }

    @Test func cancelledTerminationStillCleansUp() async throws {
        let handle = try SpawnLauncher().launch(
            argv: ["/bin/sleep", "60"], environment: [:], cwd: NSTemporaryDirectory()
        )
        let task = Task { await handle.terminate() }
        task.cancel()
        await task.value
        #expect(kill(-handle.pid, 0) == -1 && errno == ESRCH)
    }

    @Test func launchUsesExplicitEnvironmentWorkingDirectoryAndNullStdin() async throws {
        let directory = try TempDir()
        defer { directory.remove() }
        let handle = try SpawnLauncher().launch(
            argv: ["/bin/sh", "-c", "printf '%s\\n' \"$TOKEN\" \"${HOME-unset}\"; /bin/pwd -P; /bin/cat; exit 23"],
            environment: ["TOKEN": "value"], cwd: directory.path
        )
        #expect(await handle.exitStatus() == 23)
        #expect(await handle.exitStatus() == 23)
        let diagnostics = await handle.diagnostics()
        #expect(diagnostics.stdout == "value\nunset\n\(directory.path)\n")
        #expect(diagnostics.stderr.isEmpty)
    }

    @Test func launchFailureThrowsWithoutChangingParentDirectory() throws {
        let cwd = FileManager.default.currentDirectoryPath
        #expect(throws: POSIXError.self) {
            try SpawnLauncher().launch(argv: ["/no/such/executable"], environment: [:], cwd: "/")
        }
        #expect(throws: POSIXError.self) {
            try SpawnLauncher().launch(argv: ["/usr/bin/true"], environment: [:], cwd: "/no/such/directory")
        }
        #expect(throws: POSIXError.self) {
            try SpawnLauncher().launch(argv: [], environment: [:], cwd: "/")
        }
        #expect(FileManager.default.currentDirectoryPath == cwd)
    }

    @Test func diagnosticsKeepTailOfStderr() async throws {
        let handle = try SpawnLauncher().launch(
            argv: ["/bin/sh", "-c", "echo 'MCP server foo failed to connect' >&2"],
            environment: [:], cwd: NSTemporaryDirectory()
        )
        #expect(await handle.exitStatus() == 0)
        #expect(await handle.diagnostics().stderr.contains("MCP server foo failed"))
    }

    @Test func diagnosticsDrainBothPipesAndKeepOnlyTheirLast256KB() async throws {
        let handle = try SpawnLauncher().launch(
            argv: ["/bin/sh", "-c", "(/usr/bin/head -c 1048576 /dev/zero; printf out) & { /usr/bin/head -c 1048576 /dev/zero; printf err; } >&2; wait"],
            environment: [:], cwd: NSTemporaryDirectory()
        )
        #expect(await handle.exitStatus() == 0)
        let diagnostics = await handle.diagnostics()
        #expect(diagnostics.stdout.utf8.count == 262_144)
        #expect(diagnostics.stderr.utf8.count == 262_144)
        #expect(diagnostics.stdout.hasSuffix("out"))
        #expect(diagnostics.stderr.hasSuffix("err"))
    }
}
