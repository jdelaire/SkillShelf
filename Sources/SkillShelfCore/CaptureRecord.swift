import Foundation

public struct CapturedRequest: Codable, Sendable, Hashable {
    public let method: String
    public let path: String
    public let body: String
    public let bodyEncoding: String?

    public init(method: String, path: String, body: String, bodyEncoding: String?) {
        self.method = method
        self.path = path
        self.body = body
        self.bodyEncoding = bodyEncoding
    }
}

public struct CaptureRecord: Codable, Sendable {
    public let harness: String
    public let version: String?
    public let adapter: String
    public let command: [String]
    public let date: Date
    public let notes: [String]
    public let requests: [CapturedRequest]
    public let diagnostics: String?

    public init(
        harness: String, version: String?, adapter: String, command: [String], date: Date,
        notes: [String], requests: [CapturedRequest], diagnostics: String?
    ) {
        self.harness = harness
        self.version = version
        self.adapter = adapter
        self.command = command
        self.date = date
        self.notes = notes
        self.requests = requests
        self.diagnostics = diagnostics
    }

    public func save(to directory: String) throws -> String {
        let files = FileManager.default
        try files.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let path = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(formatter.string(from: date) + ".json").path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard files.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return path
    }

    public static func load(_ path: String) throws -> CaptureRecord {
        try JSONDecoder().decode(CaptureRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}
