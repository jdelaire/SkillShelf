import Foundation
import Testing
@testable import SkillShelfCore

struct CaptureParserTests {
    @Test func captureIndexListsNewestFirst() async throws {
        let f = try Fixture(); defer { f.remove() }
        let date = Date(timeIntervalSince1970: 1_793_318_400)
        let body = #"{"input":"SKILLSHELF_CAPTURE_X","tools":[{"name":"shell"}]}"#
        let older = try CaptureRecord(
            harness: "claude", version: "2.1.312", adapter: "claude", command: [], date: date,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/v1/messages", body: body, bodyEncoding: nil)],
            diagnostics: nil
        ).save(to: f.layout.path("captures/claude"))
        let newer = try CaptureRecord(
            harness: "claude", version: "2.1.313", adapter: "claude", command: [], date: date.addingTimeInterval(1),
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/v1/messages", body: "SKILLSHELF_CAPTURE_X", bodyEncoding: nil)],
            diagnostics: nil
        ).save(to: f.layout.path("captures/claude"))

        let parts = await CaptureIndex.list(harness: .claude, capturesRoot: f.layout.path("captures"))

        #expect(parts.map(\.source) == [.capture(path: newer), .capture(path: older)])
        #expect(parts.map(\.version) == ["2.1.313", "2.1.312"])
        #expect(parts[0].title == "2026-10-30T00:00:01.000Z · Main request: best guess")
        #expect(parts[1].title == "2026-10-30T00:00:00.000Z · Main request: found")
        #expect(parts.allSatisfy { $0.harness == .claude && $0.layer == .capture && $0.status == .present })
    }

    @Test func captureIndexReadsSavedHeaderWithoutParsingBodies() async throws {
        let f = try Fixture(); defer { f.remove() }
        let body = #"{"input":"SKILLSHELF_CAPTURE_X","tools":[{"name":"shell"}]}"#
        let path = try CaptureRecord(
            harness: "codex", version: "0.164.0", adapter: "codex", command: [], date: Date(timeIntervalSince1970: 1_793_318_400),
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/v1/responses", body: body, bodyEncoding: nil)],
            diagnostics: nil
        ).save(to: f.layout.path("captures/codex"))
        let saved = try Data(contentsOf: URL(fileURLWithPath: path))
        var large = Data(saved.prefix { $0 != 10 })
        large.append(10)
        large.append(Data(String(repeating: "invalid body", count: 30_000).utf8))
        try large.write(to: URL(fileURLWithPath: path))

        let parts = await CaptureIndex.list(harness: .codex, capturesRoot: f.layout.path("captures"))

        #expect(parts.count == 1)
        #expect(parts.first?.title.hasSuffix("Main request: found") == true)
        #expect(parts.first?.version == "0.164.0")
    }

    @Test func captureIndexLegacyRecordHasUnknownMainRequest() async throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "claude", version: nil, adapter: "claude", command: [], date: .now,
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/v1/messages", body: "SKILLSHELF_CAPTURE_X", bodyEncoding: nil)],
            diagnostics: nil
        )
        try f.write("captures/claude/2026-10-30T00:00:00.000Z.json", String(decoding: JSONEncoder().encode(record), as: UTF8.self))

        let parts = await CaptureIndex.list(harness: .claude, capturesRoot: f.layout.path("captures"))

        #expect(parts.count == 1)
        #expect(parts.first?.title == "2026-10-30T00:00:00.000Z · Main request: unknown")
    }

    @Test func captureIndexNeverReadsHeaderBeyond64KB() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = try CaptureRecord(
            harness: "claude", version: "2.1.312", adapter: "claude", command: [], date: Date(timeIntervalSince1970: 1_793_318_400),
            notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [CapturedRequest(method: "POST", path: "/v1/messages", body: "SKILLSHELF_CAPTURE_X", bodyEncoding: nil)],
            diagnostics: nil
        ).save(to: f.layout.path("captures/claude"))
        var padded = Data(repeating: 32, count: 64 * 1024)
        padded.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        try padded.write(to: URL(fileURLWithPath: path))

        let parts = await CaptureIndex.list(harness: .claude, capturesRoot: f.layout.path("captures"))

        #expect(parts.count == 1)
        #expect(parts.first?.title.hasSuffix("Main request: unknown") == true)
        #expect(parts.first?.version == nil)
    }

    @Test func captureIndexIgnoresOtherFilesAndMissingDirectories() async throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("captures/claude/readme.txt", "ignored")
        try f.write("captures/claude/not-a-date.json", "{}")
        try f.write("captures/claude/2026-10-30T00:00:00.000Z.json/child", "directory")

        #expect(await CaptureIndex.list(harness: .claude, capturesRoot: f.layout.path("captures")).isEmpty)
        #expect(await CaptureIndex.list(harness: .codex, capturesRoot: f.layout.path("captures")).isEmpty)
    }

    @Test func anthropicBodySplitsSystemToolsMessages() throws {
        let body = #"{"system":[{"type":"text","text":"You are X"}],"tools":[{"name":"Bash","description":"Run.\nMore","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#
        let sections = CaptureParser.sections(body)
        #expect(sections.system == ["You are X"])
        #expect(sections.tools.map(\.name) == ["Bash"])
        #expect(sections.tools.first?.summary == "Run.")
        #expect(sections.messages.map(\.role) == ["user"])
        #expect(sections.messages.map(\.text) == ["hi"])
        #expect(sections.raw == nil)
        let toolsJSON = try #require(sections.toolsJSON)
        #expect(toolsJSON.contains("\n"))
        let tools = try #require(JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as? [[String: Any]])
        #expect(tools.first?["description"] as? String == "Run.\nMore")
        #expect((tools.first?["input_schema"] as? [String: String])?["type"] == "object")
    }

    @Test func anthropicStringsAndTextBlocksArePreserved() {
        let sections = CaptureParser.sections(#"{"system":"Base","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":[{"type":"text","text":"first"},{"type":"tool_use","name":"shell"},{"type":"text","text":"second"}]}]}"#)
        #expect(sections.system == ["Base"])
        #expect(sections.messages.map(\.role) == ["user", "assistant"])
        #expect(sections.messages.map(\.text) == ["hello", "first\nsecond"])
        #expect(sections.tools.isEmpty)
        #expect(sections.toolsJSON == nil)

        let blocks = CaptureParser.sections(#"{"system":[{"type":"text","text":"One"},{"type":"text","text":"Two"}],"messages":[]}"#)
        #expect(blocks.system == ["One", "Two"])
        #expect(blocks.raw == nil)
    }

    @Test func responsesBodySplitsInstructionsInputTools() {
        let sections = CaptureParser.sections(#"{"instructions":"Base","input":[{"role":"developer","content":[{"type":"input_text","text":"dev"}]},{"role":"user","content":"hi"},{"type":"function_call","name":"shell","arguments":"{}"},{"role":"assistant","content":[{"type":"output_text","text":"answer"},{"type":"output_text","text":"more"}]}],"tools":[{"type":"function","name":"shell","description":"Run\nMore"}]}"#)
        #expect(sections.system == ["Base"])
        #expect(sections.messages.map(\.role) == ["developer", "user", "assistant"])
        #expect(sections.messages.map(\.text) == ["dev", "hi", "answer\nmore"])
        #expect(sections.tools.map(\.name) == ["shell"])
        #expect(sections.tools.first?.summary == "Run")
        #expect(sections.toolsJSON?.contains("\"function\"") == true)
        #expect(sections.raw == nil)
    }

    @Test func chatCompletionsBodySplitsSystemRolesAndNestedTools() throws {
        let body = #"{"messages":[{"role":"system","content":"fixture-system"},{"role":"developer","content":[{"type":"text","text":"fixture-dev-one"},{"type":"text","text":"fixture-dev-two"}]},{"role":"system","content":[{"type":"text","text":"fixture-system-two"}]},{"role":"user","content":"SKILLSHELF_CAPTURE_X"},{"role":"assistant","content":[{"type":"text","text":"fixture-answer"}]},{"role":"tool","tool_call_id":"fixture-call","content":"fixture-result"}],"tools":[{"type":"function","function":{"name":"fixtureTool","description":"fixture-summary\nfixture-details","parameters":{"type":"object","properties":{}}}},{"type":"function","function":{"name":"otherTool","parameters":{"type":"object"}}}]}"#
        let sections = CaptureParser.sections(body)
        #expect(sections.system == ["fixture-system", "fixture-dev-one\nfixture-dev-two", "fixture-system-two"])
        #expect(sections.messages.map(\.role) == ["user", "assistant", "tool"])
        #expect(sections.messages.map(\.text) == ["SKILLSHELF_CAPTURE_X", "fixture-answer", "fixture-result"])
        #expect(sections.tools.map(\.name) == ["fixtureTool", "otherTool"])
        #expect(sections.tools.map(\.summary) == ["fixture-summary", ""])
        #expect(sections.raw == nil)
        let json = try #require(sections.toolsJSON)
        let tools = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["description"] as? String == "fixture-summary\nfixture-details")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")

        let withoutTools = #"{"messages":[{"role":"user","content":"SKILLSHELF_CAPTURE_X"}],"tools":[]}"#
        let helper = #"{"messages":[{"role":"user","content":"fixture-helper"}],"tools":[{"type":"function","function":{"name":"helperTool"}}]}"#
        let requests = [helper, withoutTools, body].map {
            CapturedRequest(method: "POST", path: "/v1/chat/completions", body: $0, bodyEncoding: nil)
        }
        #expect(CaptureParser.hasTools(body))
        #expect(!CaptureParser.hasTools(withoutTools))
        #expect(CaptureParser.mainRequest(requests, sentinel: "SKILLSHELF_CAPTURE_X") == .found(2))
        #expect(CaptureParser.mainRequest(Array(requests.prefix(2)), sentinel: "SKILLSHELF_CAPTURE_X") == .bestGuess(1))
        #expect(CaptureParser.mainRequest([requests[0]], sentinel: "SKILLSHELF_CAPTURE_X") == .unknown)
    }

    @Test func responsesStringInputIsUserMessage() {
        let sections = CaptureParser.sections(#"{"input":"hello"}"#)
        #expect(sections.system.isEmpty)
        #expect(sections.messages.map(\.role) == ["user"])
        #expect(sections.messages.map(\.text) == ["hello"])
    }

    @Test func responsesBuiltInToolFallsBackToType() {
        let body = #"{"input":"hi","tools":[{"type":"web_search"}]}"#
        let sections = CaptureParser.sections(body)
        #expect(CaptureParser.hasTools(body))
        #expect(sections.tools.map(\.name) == ["web_search"])
        #expect(sections.tools.map(\.summary) == [""])
    }

    @Test func responsesMixedToolsPreserveNamesTypesAndOrder() throws {
        let sections = CaptureParser.sections(#"{"input":"hi","tools":[{"type":"web_search"},{"type":"function","name":"shell","description":"Run.\nMore"},{"type":"file_search","description":"Search.\nMore"}]}"#)
        #expect(sections.tools.map(\.name) == ["web_search", "shell", "file_search"])
        #expect(sections.tools.map(\.summary) == ["", "Run.", "Search."])
        let toolsJSON = try #require(sections.toolsJSON)
        let tools = try #require(JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as? [[String: Any]])
        #expect(tools.map { $0["type"] as? String } == ["web_search", "function", "file_search"])
        #expect(tools.map { $0["name"] as? String } == [nil, "shell", nil])
    }

    @Test func responsesAdditionalToolsSelectMainRequest() throws {
        let body = #"{"input":[{"type":"additional_tools","role":"developer","tools":[{"type":"function","name":"shell","description":"Run.\nMore","parameters":{"type":"object"}},{"type":"web_search"}]},{"type":"message","role":"user","content":"SKILLSHELF_CAPTURE_X"}]}"#
        let request = CapturedRequest(method: "POST", path: "/v1/responses", body: body, bodyEncoding: nil)
        #expect(CaptureParser.hasTools(body))
        #expect(CaptureParser.mainRequest([request], sentinel: "SKILLSHELF_CAPTURE_X") == .found(0))
        let sections = CaptureParser.sections(body)
        #expect(sections.tools.map(\.name) == ["shell", "web_search"])
        #expect(sections.tools.map(\.summary) == ["Run.", ""])
        let toolsJSON = try #require(sections.toolsJSON)
        let tools = try #require(JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as? [[String: Any]])
        #expect(tools.count == 2)
        #expect((tools.first?["parameters"] as? [String: String])?["type"] == "object")
    }

    @Test func responsesAdditionalToolsMergeAfterTopLevelInInputOrder() throws {
        let body = #"{"tools":[{"name":"first"}],"input":[{"type":"additional_tools","tools":[{"type":"web_search"},{"name":"second","description":"Search\nMore"}]},{"type":"message","tools":[{"name":"ignored"}]},{"type":"additional_tools","tools":[]},{"type":"additional_tools","tools":[{"name":"first"},{"type":"file_search"}]}]}"#
        let sections = CaptureParser.sections(body)
        #expect(sections.tools.map(\.name) == ["first", "web_search", "second", "first", "file_search"])
        #expect(sections.tools.map(\.summary) == ["", "", "Search", "", ""])
        let toolsJSON = try #require(sections.toolsJSON)
        let tools = try #require(JSONSerialization.jsonObject(with: Data(toolsJSON.utf8)) as? [[String: Any]])
        #expect(tools.count == 5)
        #expect(tools.last?["type"] as? String == "file_search")
    }

    @Test(arguments: [
        #"{"input":[{"type":"additional_tools","tools":[]}]}"#,
        #"{"input":[{"type":"additional_tools","tools":{"name":"shell"}}]}"#,
        #"{"input":[{"type":"message","tools":[{"name":"shell"}]}]}"#,
        #"{"input":[{"tools":[{"name":"shell"}]}]}"#,
        #"{"input":{"type":"additional_tools","tools":[{"name":"shell"}]}}"#
    ])
    func responsesAdditionalToolsRequireTypedInputArray(_ body: String) {
        #expect(!CaptureParser.hasTools(body))
        #expect(CaptureParser.sections(body).tools.isEmpty)
    }

    @Test func toolsWithoutDescriptionHaveEmptySummary() {
        let sections = CaptureParser.sections(#"{"input":[],"tools":[{"name":"shell"}]}"#)
        #expect(sections.tools.map(\.name) == ["shell"])
        #expect(sections.tools.first?.summary == "")
    }

    @Test func unknownBodyFallsBackToSortedPrettyRaw() throws {
        let sections = CaptureParser.sections(#"{"weird":1,"alpha":2}"#)
        let raw = try #require(sections.raw)
        #expect(raw.contains("\"weird\" : 1"))
        #expect(raw.contains("\n"))
        #expect(try #require(raw.range(of: "alpha")).lowerBound < #require(raw.range(of: "weird")).lowerBound)
        #expect(sections.system.isEmpty)
        #expect(sections.tools.isEmpty)
        #expect(sections.toolsJSON == nil)
        #expect(sections.messages.isEmpty)
    }

    @Test(arguments: ["not JSON", "{broken", ""])
    func invalidJSONKeepsOriginalBody(_ body: String) {
        #expect(CaptureParser.sections(body).raw == body)
        #expect(!CaptureParser.hasTools(body))
    }

    @Test func nonObjectJSONFallsBackToRaw() {
        #expect(CaptureParser.sections("[1,2]").raw == "[\n  1,\n  2\n]")
        #expect(CaptureParser.sections("true").raw == "true")
    }

    @Test func hasToolsRequiresNonemptyArray() {
        #expect(CaptureParser.hasTools(#"{"tools":[{"name":"shell"}]}"#))
        #expect(!CaptureParser.hasTools(#"{"tools":[]}"#))
        #expect(!CaptureParser.hasTools(#"{"tools":{"name":"shell"}}"#))
        #expect(!CaptureParser.hasTools(#"{"tools":null}"#))
        #expect(!CaptureParser.hasTools("{}"))
    }

    @Test func mainRequestPrefersSentinelWithTools() {
        let sentinel = "SKILLSHELF_CAPTURE_X"
        let title = CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"messages":[{"role":"user","content":"\#(sentinel)"}]}"#, bodyEncoding: nil)
        let main = CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"tools":[{"name":"a"}],"messages":[{"role":"user","content":"\#(sentinel)"}]}"#, bodyEncoding: nil)
        let unrelated = CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"tools":[{"name":"a"}],"messages":[]}"#, bodyEncoding: nil)
        #expect(CaptureParser.mainRequest([unrelated, title, main, main], sentinel: sentinel) == .found(2))
        #expect(CaptureParser.mainRequest([unrelated, title, title], sentinel: sentinel) == .bestGuess(1))
        #expect(CaptureParser.mainRequest([unrelated], sentinel: sentinel) == .unknown)
        #expect(CaptureParser.mainRequest([], sentinel: sentinel) == .unknown)
    }

    @Test func savedRecordIsPrivate() throws {
        let f = try Fixture(); defer { f.remove() }
        let path = try CaptureRecord(harness: "claude", version: "2.1.312", adapter: "anthropic", command: ["claude", "-p"], date: .now, notes: [], requests: [], diagnostics: nil).save(to: f.layout.path("captures/claude"))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        for directory in ["captures", "captures/claude"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: f.layout.path(directory))
            #expect((attrs[.posixPermissions] as? Int) == 0o700)
        }
    }

    @Test func savedRecordRoundTripsDiagnosticsAndSentinel() throws {
        let f = try Fixture(); defer { f.remove() }
        let record = CaptureRecord(
            harness: "claude", version: "2.1.312", adapter: "anthropic", command: ["claude", "-p"],
            date: Date(timeIntervalSince1970: 1_793_318_400), notes: ["sentinel: SKILLSHELF_CAPTURE_X"],
            requests: [
                CapturedRequest(method: "POST", path: "/v1/messages", body: #"{"tools":[{"name":"shell"}],"messages":[{"role":"user","content":"SKILLSHELF_CAPTURE_X"}]}"#, bodyEncoding: nil),
                CapturedRequest(method: "POST", path: "/v1/messages", body: "eA==", bodyEncoding: "gzip"),
            ], diagnostics: "MCP failed\nDetails"
        )
        let path = try record.save(to: f.layout.path("captures/claude"))
        #expect((path as NSString).lastPathComponent == "2026-10-30T00:00:00.000Z.json")
        let loaded = try CaptureRecord.load(path)
        #expect(loaded.harness == "claude")
        #expect(loaded.version == "2.1.312")
        #expect(loaded.adapter == "anthropic")
        #expect(loaded.command == ["claude", "-p"])
        #expect(loaded.date == record.date)
        #expect(loaded.notes == ["sentinel: SKILLSHELF_CAPTURE_X"])
        #expect(loaded.requests == record.requests)
        #expect(loaded.diagnostics == "MCP failed\nDetails")
        let sentinel = String(try #require(loaded.notes.first).dropFirst("sentinel: ".count))
        #expect(CaptureParser.mainRequest(loaded.requests, sentinel: sentinel) == .found(0))
    }

    @Test func savedRecordRoundTripsMissingOptionalFields() throws {
        let f = try Fixture(); defer { f.remove() }
        let path = try CaptureRecord(harness: "codex", version: nil, adapter: "responses", command: [], date: .now, notes: [], requests: [], diagnostics: nil).save(to: f.layout.path("captures/codex"))
        let loaded = try CaptureRecord.load(path)
        #expect(loaded.version == nil)
        #expect(loaded.diagnostics == nil)
        #expect(loaded.requests.isEmpty)
    }

    @Test func saveMakesExistingDirectoryPrivate() throws {
        let f = try Fixture(); defer { f.remove() }
        let directory = f.layout.path("captures/claude")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        _ = try CaptureRecord(harness: "claude", version: nil, adapter: "anthropic", command: [], date: .now, notes: [], requests: [], diagnostics: nil).save(to: directory)
        let attrs = try FileManager.default.attributesOfItem(atPath: directory)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func saveAndLoadFailuresThrow() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.write("not-directory", "occupied")
        let record = CaptureRecord(harness: "claude", version: nil, adapter: "anthropic", command: [], date: .now, notes: [], requests: [], diagnostics: nil)
        #expect(throws: (any Error).self) { try record.save(to: f.layout.path("not-directory/claude")) }
        let path = try record.save(to: f.layout.path("captures/claude"))
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try record.save(to: f.layout.path("captures/claude")) }
        #expect(throws: (any Error).self) { try CaptureRecord.load(f.layout.path("missing.json")) }
        try f.write("invalid.json", "{}")
        #expect(throws: (any Error).self) { try CaptureRecord.load(f.layout.path("invalid.json")) }
    }
}
