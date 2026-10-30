import Foundation
import Testing
@testable import SkillShelfCore

struct CaptureParserTests {
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
