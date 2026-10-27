import Foundation

public enum HarnessID: String, CaseIterable, Sendable, Identifiable, Hashable {
    case claude, codex, cursor, opencode, grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .grok: "Grok"
        }
    }
}

public enum RootKind: Sendable, Hashable {
    case user, builtIn, managed, plugin
}

public struct PluginRef: Sendable, Hashable {
    public let owner: HarnessID
    public let id: String
    public let removable: Bool

    public init(owner: HarnessID, id: String, removable: Bool) {
        self.owner = owner
        self.id = id
        self.removable = removable
    }
}

public struct Root: Sendable, Hashable {
    public let path: String
    public let kind: RootKind
    public let plugin: PluginRef?

    public init(path: String, kind: RootKind, plugin: PluginRef? = nil) {
        self.path = path
        self.kind = kind
        self.plugin = plugin
    }
}

public struct HarnessRoot: Sendable, Hashable {
    public let root: Root
    public let thirdParty: Bool

    public init(root: Root, thirdParty: Bool = false) {
        self.root = root
        self.thirdParty = thirdParty
    }
}

public enum Protection: Sendable, Hashable {
    case none
    case builtIn
    case managed
    case plugin(PluginRef)
}

public struct SkillEntry: Sendable, Hashable, Identifiable {
    public let root: Root
    public let folderName: String
    public let entryPath: String
    public let linkDestination: String?
    public let resolvedPath: String?
    public let name: String
    public let description: String
    public let protection: Protection

    public var id: String { entryPath }
    public var isSymlink: Bool { linkDestination != nil }
    public var isBroken: Bool { resolvedPath == nil }

    public init(
        root: Root,
        folderName: String,
        entryPath: String,
        linkDestination: String?,
        resolvedPath: String?,
        name: String,
        description: String,
        protection: Protection
    ) {
        self.root = root
        self.folderName = folderName
        self.entryPath = entryPath
        self.linkDestination = linkDestination
        self.resolvedPath = resolvedPath
        self.name = name
        self.description = description
        self.protection = protection
    }
}

public struct HarnessRow: Sendable, Hashable, Identifiable {
    public let entry: SkillEntry
    public let thirdParty: Bool
    public let duplicate: Bool

    public var id: String { entry.id }
}

public struct Snapshot: Sendable {
    public let generation: Int
    public let entries: [SkillEntry]
    public let harnessRoots: [HarnessID: [HarnessRoot]]
    public let notes: [String]

    public init(generation: Int, entries: [SkillEntry], harnessRoots: [HarnessID: [HarnessRoot]], notes: [String]) {
        self.generation = generation
        self.entries = entries
        self.harnessRoots = harnessRoots
        self.notes = notes
    }

    public static let empty = Snapshot(generation: 0, entries: [], harnessRoots: [:], notes: [])

    public func rows(for harness: HarnessID) -> [HarnessRow] {
        let roots = harnessRoots[harness] ?? []
        var rows: [HarnessRow] = []
        for harnessRoot in roots {
            for entry in entries where entry.root.path == harnessRoot.root.path {
                rows.append(HarnessRow(entry: entry, thirdParty: harnessRoot.thirdParty, duplicate: false))
            }
        }
        var counts: [String: Int] = [:]
        for row in rows { counts[row.entry.folderName, default: 0] += 1 }
        return rows.map {
            HarnessRow(entry: $0.entry, thirdParty: $0.thirdParty, duplicate: counts[$0.entry.folderName, default: 0] > 1)
        }
    }

    public func allRows() -> [HarnessRow] {
        entries.map { HarnessRow(entry: $0, thirdParty: false, duplicate: false) }
    }

    public func seenBy(_ entry: SkillEntry) -> [(HarnessID, Bool)] {
        HarnessID.allCases.compactMap { harness in
            guard let match = harnessRoots[harness]?.first(where: { $0.root.path == entry.root.path }) else { return nil }
            return (harness, match.thirdParty)
        }
    }

    public func entry(id: String) -> SkillEntry? {
        entries.first { $0.id == id }
    }
}
