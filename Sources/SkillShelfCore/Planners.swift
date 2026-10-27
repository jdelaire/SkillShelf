import Foundation

public struct PathExpectation: Sendable, Hashable {
    public let path: String
    public let linkDestination: String?
    public let fileNumber: UInt64?

    public init(path: String, linkDestination: String?, fileNumber: UInt64? = nil) {
        self.path = path
        self.linkDestination = linkDestination
        self.fileNumber = fileNumber
    }

    static func folder(_ path: String) -> PathExpectation {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let number = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        return PathExpectation(path: path, linkDestination: nil, fileNumber: number)
    }
}

public struct PluginUninstall: Sendable, Hashable {
    public let plugin: PluginRef
    public let tool: String
    public let arguments: [String]
    public let skills: [String]

    public var commandLine: String { ([tool] + arguments).joined(separator: " ") }
}

public struct DeleteOption: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        case trash(items: [PathExpectation], lockKey: String?)
        case uninstall(PluginUninstall)
    }

    public let title: String
    public let detail: String
    public let action: Action

    public var id: String { title }

    public var affectedPaths: [String] {
        switch action {
        case .trash(let items, _): items.map(\.path)
        case .uninstall(let uninstall): uninstall.skills
        }
    }
}

public enum DeletePlanner {
    public enum Result: Sendable {
        case blocked(String)
        case options([DeleteOption])
    }

    public static func plan(for entry: SkillEntry, in snapshot: Snapshot, layout: Layout) -> Result {
        switch entry.root.kind {
        case .builtIn:
            return .blocked("Built into the harness. It cannot be deleted here.")
        case .managed:
            return .blocked("Claude re-downloads this skill. Turn it off on claude.ai instead.")
        case .plugin:
            return pluginResult(entry.root.plugin, snapshot)
        case .user:
            break
        }
        if entry.isSymlink {
            return .options(linkOptions(entry, snapshot, layout))
        }
        switch entry.protection {
        case .builtIn, .managed:
            return .blocked("This folder belongs to the harness. It cannot be deleted here.")
        case .plugin(let plugin):
            return pluginResult(plugin, snapshot)
        case .none:
            guard Paths.canonical(entry.entryPath) == entry.entryPath else {
                let real = entry.resolvedPath.map(layout.display) ?? "another folder"
                return .blocked("This skills folder is itself a link to \(real). Delete the skill there.")
            }
            let links = incomingLinks(to: entry.entryPath, snapshot)
            let detail = links.isEmpty
                ? "Moves the folder to the Trash."
                : "Moves the folder and \(links.count) link\(links.count == 1 ? "" : "s") to it to the Trash."
            return .options([DeleteOption(
                title: "Delete everywhere",
                detail: detail,
                action: .trash(items: links + [.folder(entry.entryPath)], lockKey: lockKey(for: entry.entryPath, layout))
            )])
        }
    }

    static func pluginResult(_ plugin: PluginRef?, _ snapshot: Snapshot) -> Result {
        guard let plugin, plugin.removable else {
            return .blocked("Part of a plugin bundled with its harness. It cannot be uninstalled here.")
        }
        return .options([uninstallOption(plugin, snapshot)])
    }

    static func linkOptions(_ entry: SkillEntry, _ snapshot: Snapshot, _ layout: Layout) -> [DeleteOption] {
        let own = PathExpectation(path: entry.entryPath, linkDestination: entry.linkDestination)
        var options = [DeleteOption(
            title: "Remove this link",
            detail: "Moves only this link to the Trash. The skill folder stays.",
            action: .trash(items: [own], lockKey: nil)
        )]
        guard let resolved = entry.resolvedPath, entry.protection == .none else { return options }
        let links = incomingLinks(to: resolved, snapshot)
        if let owner = userRootFolder(at: resolved, snapshot) {
            options.append(DeleteOption(
                title: "Delete everywhere",
                detail: "Moves the folder and every link to it to the Trash.",
                action: .trash(items: links + [.folder(owner.entryPath)], lockKey: lockKey(for: owner.entryPath, layout))
            ))
        } else if links.count > 1 {
            options.append(DeleteOption(
                title: "Remove all links",
                detail: "The folder lives outside the skill folders (\(layout.display(resolved))), so it stays. Moves every link to it to the Trash.",
                action: .trash(items: links, lockKey: nil)
            ))
        }
        return options
    }

    static func uninstallOption(_ plugin: PluginRef, _ snapshot: Snapshot) -> DeleteOption {
        let skills = snapshot.entries.filter { $0.root.plugin == plugin }.map(\.name)
        let tool: String
        let arguments: [String]
        switch plugin.owner {
        case .codex:
            tool = "codex"
            arguments = ["plugin", "remove", plugin.id]
        default:
            tool = "claude"
            arguments = ["plugin", "uninstall", plugin.id, "--scope", "user"]
        }
        let uninstall = PluginUninstall(plugin: plugin, tool: tool, arguments: arguments, skills: skills)
        return DeleteOption(
            title: "Uninstall plugin \(plugin.id)",
            detail: "Runs `\(uninstall.commandLine)`. Removes every skill in the plugin.",
            action: .uninstall(uninstall)
        )
    }

    static func incomingLinks(to resolved: String, _ snapshot: Snapshot) -> [PathExpectation] {
        snapshot.entries
            .filter { $0.root.kind == .user && $0.isSymlink && $0.resolvedPath == resolved }
            .map { PathExpectation(path: $0.entryPath, linkDestination: $0.linkDestination) }
    }

    static func userRootFolder(at resolved: String, _ snapshot: Snapshot) -> SkillEntry? {
        snapshot.entries.first {
            !$0.isSymlink && $0.root.kind == .user && $0.entryPath == resolved && Paths.canonical($0.entryPath) == $0.entryPath
        }
    }

    static func lockKey(for path: String, _ layout: Layout) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == layout.agentsSkills ? (path as NSString).lastPathComponent : nil
    }
}

public struct PushStep: Sendable, Hashable, Identifiable {
    public enum Outcome: Sendable, Hashable {
        case present(via: String)
        case link(path: String, destination: String)
        case conflict(String)
    }

    public let harness: HarnessID
    public let outcome: Outcome
    public let target: String

    public var id: HarnessID { harness }
}

public enum PushPlanner {
    public enum Result: Sendable {
        case blocked(String)
        case steps([PushStep])
    }

    enum Found {
        case none, match, other(String)
    }

    public static func plan(for entry: SkillEntry, in snapshot: Snapshot, layout: Layout) -> Result {
        guard let target = entry.resolvedPath else { return .blocked("This link is broken.") }
        guard entry.root.kind == .user, entry.protection == .none else {
            return .blocked("Built-in, managed and plugin skills belong to their harness and cannot be pushed.")
        }
        let name = (target as NSString).lastPathComponent
        var planned = Set<String>()
        var steps: [PushStep] = []
        for harness in snapshot.harnesses {
            let roots = (snapshot.harnessRoots[harness] ?? []).filter { !$0.thirdParty }.map(\.root.path)
            var matchRoot: String?
            var clash: String?
            for root in roots {
                switch inspect(root: root, name: name, target: target, planned: planned) {
                case .none: break
                case .match: matchRoot = matchRoot ?? root
                case .other(let reason): clash = clash ?? "\(reason) in \(layout.display(root))."
                }
            }
            let outcome: PushStep.Outcome
            if let clash {
                outcome = .conflict(clash)
            } else if let matchRoot {
                outcome = .present(via: layout.display(matchRoot))
            } else {
                let pushRoot = layout.pushRoot(for: harness)
                let physicalRoot = physical(pushRoot)
                outcome = .link(path: pushRoot + "/" + name, destination: Paths.relative(from: physicalRoot, to: target))
                planned.insert(physicalRoot + "/" + name)
            }
            steps.append(PushStep(harness: harness, outcome: outcome, target: target))
        }
        return .steps(steps)
    }

    static func inspect(root: String, name: String, target: String, planned: Set<String>) -> Found {
        let path = root + "/" + name
        if planned.contains(physical(root) + "/" + name) { return .match }
        let files = FileManager.default
        let isLink = (try? files.destinationOfSymbolicLink(atPath: path)) != nil
        guard isLink || files.fileExists(atPath: path) else { return .none }
        guard let resolved = Paths.canonical(path) else { return .other("A broken link named \(name) is already") }
        guard resolved == target, files.fileExists(atPath: target + "/SKILL.md") else {
            return .other("A different \(name) is already")
        }
        return .match
    }

    static func physical(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while Paths.canonical(existing) == nil, existing != "/", !existing.isEmpty {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let base = Paths.canonical(existing) ?? existing
        return ([base] + missing).joined(separator: "/")
    }
}
