import Foundation

public enum PromptLayer: Sendable, Hashable {
    case instructions, agentDefinitions, base, capture
}

public enum PromptStatus: Sendable, Hashable {
    case present
    case missing
    case unavailable(String)
}

public enum PromptSource: Sendable, Hashable {
    case file(path: String, key: String?)
    case remote(url: URL, cache: String?)
    case capture(path: String)
    case none
}

public struct PromptPart: Sendable, Identifiable, Hashable {
    public let id: String
    public let harness: HarnessID
    public let layer: PromptLayer
    public let title: String
    public let source: PromptSource
    public let status: PromptStatus
    public let version: String?
    public let notes: [String]
    private let idSuffix: String?

    public init(
        harness: HarnessID,
        layer: PromptLayer,
        title: String,
        source: PromptSource,
        status: PromptStatus,
        version: String? = nil,
        notes: [String] = [],
        idSuffix: String? = nil
    ) {
        let identity: String
        switch source {
        case .file(let path, let key): identity = path + (key.map { "#" + $0 } ?? "")
        case .remote(let url, _): identity = url.absoluteString
        case .capture(let path): identity = path
        case .none: identity = title
        }
        id = "\(harness.rawValue)/\(layer)/\(identity)" + (idSuffix.map { "#" + $0 } ?? "")
        self.harness = harness
        self.layer = layer
        self.title = title
        self.source = source
        self.status = status
        self.version = version
        self.notes = notes
        self.idSuffix = idSuffix
    }

    public var filePath: String? {
        guard case .file(let path, _) = source else { return nil }
        return path
    }

    func addingNotes(_ extra: [String]) -> PromptPart {
        PromptPart(
            harness: harness, layer: layer, title: title, source: source,
            status: status, version: version, notes: notes + extra.filter { !notes.contains($0) }, idSuffix: idSuffix
        )
    }
}
