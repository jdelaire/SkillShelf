import Darwin
import Foundation
import Synchronization
import Testing
@testable import SkillShelfCore

struct LiveCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SKILLSHELF_LIVE_CAPTURE"] == "1"))
    func liveCapture() async throws {
        let directory = try TempDir()
        defer {
            directory.remove()
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
        let runner = LoginShellRunner()
        for harness in [HarnessID.claude, .codex, .opencode] {
            let adapter = try #require(CaptureAdapters.adapter(for: harness))
            let launcher = LiveCaptureLauncher()
            let capture = PromptCapture(
                launcher: launcher,
                resolveTool: { await runner.resolve($0) },
                loginEnvironment: { await runner.loginEnvironment() },
                capturesRoot: directory.path + "/captures", tempRoot: directory.path + "/tmp"
            )
            let start = ContinuousClock.now
            do {
                let record = try CaptureRecord.load(try await capture.run(adapter, version: nil))
                let note = try #require(record.notes.first { $0.hasPrefix("sentinel: ") })
                let main = CaptureParser.mainRequest(record.requests, sentinel: String(note.dropFirst(10)))
                let tools: Int
                if case .found(let index) = main {
                    tools = CaptureParser.sections(record.requests[index].body).tools.count
                } else {
                    tools = 0
                    Issue.record("\(harness.rawValue): no main request with tools")
                }
                print("\(harness.rawValue): requests=\(record.requests.count), main=\(main), tools=\(tools), elapsed=\(ContinuousClock.now - start)")
                print("\(harness.rawValue): notes=\(record.notes)")
                print("\(harness.rawValue): diagnostics=\(safeDiagnostics(record.diagnostics ?? "<none>"))")
                #expect(tools > 0)
                #expect(ContinuousClock.now - start < .seconds(60))
            } catch {
                print("\(harness.rawValue): requests=0, main=unknown, tools=0, error=\(error.localizedDescription)")
                for handle in launcher.handles {
                    let diagnostics = await handle.diagnostics()
                    print("\(harness.rawValue): diagnostics=\(safeDiagnostics(diagnostics.stderr))")
                }
                Issue.record("\(harness.rawValue): \(error.localizedDescription)")
            }
            for handle in launcher.handles {
                #expect(kill(handle.pid, 0) == -1 && errno == ESRCH)
                #expect(kill(-handle.pid, 0) == -1 && errno == ESRCH)
            }
            print("\(harness.rawValue): cleaned process groups=\(launcher.handles.map(\.pid))")
            if FileManager.default.fileExists(atPath: directory.path + "/tmp") {
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path + "/tmp").isEmpty)
            }
        }
        for harness in [HarnessID.grok, .muse] {
            print("\(harness.rawValue): disabled, \(CaptureAdapters.unavailableReason(for: harness) ?? "Unavailable")")
        }
    }

    private func safeDiagnostics(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let sensitive = #"(?i)authorization|bearer|x-api-key|api[_ -]?key|token|cookie|secret|password|credential"#
            return line.range(of: sensitive, options: .regularExpression) == nil ? String(line) : "<redacted diagnostic line>"
        }.joined(separator: "\n")
    }
}

private final class LiveCaptureLauncher: CaptureProcessLaunching {
    private let state = Mutex<[any CaptureProcessHandle]>([])

    var handles: [any CaptureProcessHandle] { state.withLock { $0 } }

    func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle {
        let handle = try SpawnLauncher().launch(argv: argv, environment: environment, cwd: cwd)
        state.withLock { $0.append(handle) }
        return handle
    }
}
