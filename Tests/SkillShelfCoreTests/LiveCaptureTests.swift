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
        let environment = await runner.loginEnvironment()
        let home = environment["HOME"] ?? NSHomeDirectory()
        for harness in [HarnessID.claude, .codex, .opencode] {
            let adapter = try #require(CaptureAdapters.adapter(for: harness))
            let launcher = LiveCaptureLauncher()
            let codexHome = environment["CODEX_HOME"] ?? home + "/.codex"
            let opencodeHome = (environment["XDG_DATA_HOME"] ?? home + "/.local/share") + "/opencode"
            let roots: [String]
            switch harness {
            case .claude: roots = [home + "/.claude/projects", home + "/.claude/history.jsonl"]
            case .codex: roots = [codexHome + "/sessions", codexHome + "/archived_sessions", codexHome + "/history.jsonl", codexHome + "/session_index.jsonl"]
            default: roots = [opencodeHome + "/storage/session", opencodeHome + "/storage/message", opencodeHome + "/storage/part"]
            }
            let snapshot = try LiveSessionSnapshot(roots: roots)
            let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
            let capture = PromptCapture(
                launcher: launcher,
                resolveTool: { await runner.resolve($0) },
                loginEnvironment: { environment },
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
            for launch in launcher.launches {
                try snapshot.expectNoArtifacts(cwd: launch.cwd, sentinel: launch.sentinel)
                if harness == .opencode {
                    try expectNoDatabaseHistory(
                        opencodeHome + "/opencode.db", harness: harness, cwd: launch.cwd, sentinel: launch.sentinel, startedAt: startedAt
                    )
                } else if harness == .codex {
                    try expectNoDatabaseHistory(
                        codexHome + "/state_5.sqlite", harness: harness, cwd: launch.cwd, sentinel: launch.sentinel, startedAt: startedAt
                    )
                }
            }
            print("\(harness.rawValue): session artifact checks finished")
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

    private func expectNoDatabaseHistory(
        _ path: String, harness: HarnessID, cwd: String, sentinel: String, startedAt: Int64
    ) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let cwd = cwd.replacingOccurrences(of: "'", with: "''")
        let sentinel = sentinel.replacingOccurrences(of: "'", with: "''")
        let query = harness == .codex ? """
        SELECT count(*) FROM threads WHERE cwd = '\(cwd)' OR instr(first_user_message, '\(sentinel)') > 0;
        """ : """
        SELECT count(*) FROM session WHERE directory = '\(cwd)' OR instr(title, '\(sentinel)') > 0;
        SELECT count(*) FROM part WHERE session_id IN (SELECT id FROM session WHERE time_created >= \(startedAt))
            AND instr(data, '\(sentinel)') > 0;
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", path, query]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: result, as: UTF8.self) == (harness == .codex ? "0\n" : "0\n0\n"))
        #expect(kill(process.processIdentifier, 0) == -1 && errno == ESRCH)
    }
}

private final class LiveCaptureLauncher: CaptureProcessLaunching {
    struct Launch: Sendable {
        let handle: any CaptureProcessHandle
        let cwd: String
        let sentinel: String
    }

    private let state = Mutex<[Launch]>([])

    var launches: [Launch] { state.withLock { $0 } }
    var handles: [any CaptureProcessHandle] { launches.map(\.handle) }

    func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle {
        let handle = try SpawnLauncher().launch(argv: argv, environment: environment, cwd: cwd)
        let sentinel = argv.first { $0.hasPrefix("SKILLSHELF_CAPTURE_") } ?? ""
        state.withLock { $0.append(Launch(handle: handle, cwd: cwd, sentinel: sentinel)) }
        return handle
    }
}

private struct LiveSessionSnapshot {
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date?
    }

    private let roots: [String]
    private let stamps: [String: Stamp]

    init(roots: [String]) throws {
        self.roots = roots
        stamps = try Self.entries(roots).reduce(into: [:]) { result, path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if attributes[.type] as? FileAttributeType == .typeRegular {
                result[path] = Stamp(
                    size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modified: attributes[.modificationDate] as? Date
                )
            }
        }
    }

    func expectNoArtifacts(cwd: String, sentinel: String) throws {
        #expect(!sentinel.isEmpty)
        guard !sentinel.isEmpty else { return }
        let project = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let needles = [sentinel, cwd].map { Data($0.utf8) }
        let overlap = needles.map(\.count).max() ?? 0
        for path in try Self.entries(roots) {
            #expect(!path.contains(sentinel) && !(path as NSString).pathComponents.contains(project))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let stamp = Stamp(size: size, modified: attributes[.modificationDate] as? Date)
            guard stamp != stamps[path] else { continue }
            let prior = stamps[path]?.size ?? 0
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            if size > prior { try file.seek(toOffset: prior > UInt64(overlap) ? prior - UInt64(overlap) : 0) }
            var tail = Data()
            while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                let data = tail + chunk
                #expect(needles.allSatisfy { data.range(of: $0) == nil }, "Session artifact remains at \(path)")
                tail = data.suffix(overlap)
            }
        }
    }

    private static func entries(_ roots: [String]) throws -> [String] {
        var paths: [String] = []
        for root in roots {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { continue }
            paths.append(root)
            guard isDirectory.boolValue else { continue }
            var enumerationError: (any Error)?
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, error in enumerationError = error; return false }
            )
            while let url = enumerator?.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    enumerator?.skipDescendants()
                } else {
                    paths.append(url.path)
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return paths
    }
}
