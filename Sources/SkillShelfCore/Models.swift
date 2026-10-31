import Foundation

public enum HarnessID: String, CaseIterable, Sendable, Identifiable, Hashable {
    case claude, codex, cursor, opencode, grok, antigravity, muse

    public var id: String { rawValue }

    public var detectionPaths: [String] {
        switch self {
        case .claude: [".claude"]
        case .codex: [".codex"]
        case .cursor: [".cursor"]
        case .opencode: [".config/opencode"]
        case .grok: [".grok"]
        case .antigravity: [".gemini", ".t3/tools/antigravity-acp", "/Applications/Antigravity.app"]
        case .muse: [".config/muse", ".local/share/muse"]
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        case .muse: "Muse Code"
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
    public let lockReason: String?

    public var id: String { entryPath }
    public var isDeletable: Bool { lockReason == nil }
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
        protection: Protection,
        lockReason: String? = nil
    ) {
        self.root = root
        self.folderName = folderName
        self.entryPath = entryPath
        self.linkDestination = linkDestination
        self.resolvedPath = resolvedPath
        self.name = name
        self.description = description
        self.protection = protection
        self.lockReason = lockReason
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
    public let visible: [HarnessID: Set<String>]
    public let prompts: [HarnessID: [PromptPart]]

    public init(
        generation: Int,
        entries: [SkillEntry],
        harnessRoots: [HarnessID: [HarnessRoot]],
        notes: [String],
        visible: [HarnessID: Set<String>] = [:],
        prompts: [HarnessID: [PromptPart]] = [:]
    ) {
        self.generation = generation
        self.entries = entries
        self.harnessRoots = harnessRoots
        self.notes = notes
        self.visible = visible
        self.prompts = prompts
    }

    public static let empty = Snapshot(generation: 0, entries: [], harnessRoots: [:], notes: [])

    public var harnesses: [HarnessID] {
        HarnessID.allCases.filter { harnessRoots[$0] != nil }
    }

    public func rows(for harness: HarnessID) -> [HarnessRow] {
        let roots = harnessRoots[harness] ?? []
        var rows: [HarnessRow] = []
        for harnessRoot in roots {
            for entry in entries where entry.root.path == harnessRoot.root.path && isVisible(entry, to: harness) {
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
            guard isVisible(entry, to: harness),
                  let match = harnessRoots[harness]?.first(where: { $0.root.path == entry.root.path })
            else { return nil }
            return (harness, match.thirdParty)
        }
    }

    func isVisible(_ entry: SkillEntry, to harness: HarnessID) -> Bool {
        visible[harness].map { $0.contains(entry.entryPath) } ?? true
    }

    public func entry(id: String) -> SkillEntry? {
        entries.first { $0.id == id }
    }
}
