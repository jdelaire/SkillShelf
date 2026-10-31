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
        var data = try encoder.encode(self)
        var prefix = Data(#"{"_header":"#.utf8)
        prefix.append(try JSONEncoder().encode(CaptureHeader(record: self)))
        prefix.append(UInt8(ascii: ","))
        data.replaceSubrange(data.startIndex...data.startIndex, with: prefix)
        guard files.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return path
    }

    public static func load(_ path: String) throws -> CaptureRecord {
        try JSONDecoder().decode(CaptureRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

private struct CaptureHeader: Codable {
    let version: String?
    let mainRequestStatus: String

    init(record: CaptureRecord) {
        version = record.version
        let sentinel = record.notes.first { $0.hasPrefix("sentinel: ") }
            .map { String($0.dropFirst("sentinel: ".count)) }
        let main = sentinel.flatMap {
            $0.isEmpty ? nil : CaptureParser.mainRequest(record.requests, sentinel: $0)
        } ?? .unknown
        switch main {
        case .found: mainRequestStatus = "found"
        case .bestGuess: mainRequestStatus = "best guess"
        case .unknown: mainRequestStatus = "unknown"
        }
    }
}

public enum CaptureIndex {
    @concurrent
    public static func list(harness: HarnessID, capturesRoot: String) async -> [PromptPart] {
        let directory = URL(fileURLWithPath: capturesRoot, isDirectory: true).appendingPathComponent(harness.rawValue)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        ) else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return files.compactMap { file -> (Date, PromptPart)? in
            guard file.pathExtension == "json",
                  let date = formatter.date(from: file.deletingPathExtension().lastPathComponent),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let header = header(at: file)
            return (date, PromptPart(
                harness: harness, layer: .capture,
                title: file.deletingPathExtension().lastPathComponent + " · Main request: " + (header?.mainRequestStatus ?? "unknown"),
                source: .capture(path: file.path), status: .present, version: header?.version
            ))
        }.sorted {
            $0.0 == $1.0 ? $0.1.id > $1.1.id : $0.0 > $1.0
        }.map(\.1)
    }

    private static func header(at file: URL) -> CaptureHeader? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 64 * 1024) else { return nil }
        let line = prefix.prefix { $0 != UInt8(ascii: "\n") }
        guard line.starts(with: Data(#"{"_header":"#.utf8)), line.last == UInt8(ascii: ",") else { return nil }
        var data = Data(line.dropLast())
        data.append(UInt8(ascii: "}"))
        struct Envelope: Decodable {
            let _header: CaptureHeader
        }
        return try? JSONDecoder().decode(Envelope.self, from: data)._header
    }
}
