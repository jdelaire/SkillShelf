import Foundation

public struct PathExpectation: Sendable, Hashable {
    public let path: String
    public let linkDestination: String?

    public init(path: String, linkDestination: String?) {
        self.path = path
        self.linkDestination = linkDestination
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
        if entry.isSymlink {
            return .options(linkOptions(entry, snapshot, layout))
        }
        switch entry.protection {
        case .builtIn:
            return .blocked("Built into the harness. It cannot be deleted here.")
        case .managed:
            return .blocked("Claude re-downloads this skill. Turn it off on claude.ai instead.")
        case .plugin(let plugin):
            guard plugin.removable else {
                return .blocked("Part of a plugin bundled with \(plugin.owner.displayName). It cannot be uninstalled here.")
            }
            return .options([uninstallOption(plugin, snapshot, layout)])
        case .none:
            guard let resolved = entry.resolvedPath else { return .blocked("Missing folder.") }
            let links = incomingLinks(to: resolved, snapshot)
            let detail = links.isEmpty
                ? "Moves the folder to the Trash."
                : "Moves the folder and \(links.count) link\(links.count == 1 ? "" : "s") to it to the Trash."
            return .options([DeleteOption(
                title: "Delete everywhere",
                detail: detail,
                action: .trash(items: links + [PathExpectation(path: entry.entryPath, linkDestination: nil)],
                               lockKey: lockKey(for: entry.entryPath, layout))
            )])
        }
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
        if let owner = userRootEntry(at: resolved, snapshot) {
            options.append(DeleteOption(
                title: "Delete everywhere",
                detail: "Moves the folder and every link to it to the Trash.",
                action: .trash(items: links + [PathExpectation(path: owner.entryPath, linkDestination: nil)],
                               lockKey: lockKey(for: owner.entryPath, layout))
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

    static func uninstallOption(_ plugin: PluginRef, _ snapshot: Snapshot, _ layout: Layout) -> DeleteOption {
        let skills = snapshot.entries.filter { $0.protection == .plugin(plugin) && !$0.isSymlink }.map { $0.name }
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
            .filter { $0.isSymlink && $0.resolvedPath == resolved }
            .map { PathExpectation(path: $0.entryPath, linkDestination: $0.linkDestination) }
    }

    static func userRootEntry(at resolved: String, _ snapshot: Snapshot) -> SkillEntry? {
        snapshot.entries.first { !$0.isSymlink && $0.root.kind == .user && $0.entryPath == resolved }
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

    public var id: HarnessID { harness }
}

public enum PushPlanner {
    public enum Result: Sendable {
        case blocked(String)
        case steps([PushStep])
    }

    public static func plan(for entry: SkillEntry, in snapshot: Snapshot, layout: Layout) -> Result {
        guard let target = entry.resolvedPath else { return .blocked("This link is broken.") }
        guard entry.protection == .none else {
            return .blocked("Built-in, managed and plugin skills belong to their harness and cannot be pushed.")
        }
        let name = (target as NSString).lastPathComponent
        var present: [String: [String: String?]] = [:]
        for item in snapshot.entries {
            present[item.root.path, default: [:]][item.folderName] = .some(item.resolvedPath)
        }
        var steps: [PushStep] = []
        for harness in snapshot.harnesses {
            let roots = (snapshot.harnessRoots[harness] ?? []).filter { !$0.thirdParty }.map(\.root.path)
            let found = roots.compactMap { root in present[root]?[name].map { (root: root, resolved: $0) } }
            if let match = found.first(where: { $0.resolved == target }) {
                steps.append(PushStep(harness: harness, outcome: .present(via: layout.display(match.root))))
            } else if let clash = found.first {
                let reason = clash.resolved == nil
                    ? "A broken link named \(name) is already in \(layout.display(clash.root))."
                    : "A different \(name) is already in \(layout.display(clash.root))."
                steps.append(PushStep(harness: harness, outcome: .conflict(reason)))
            } else {
                let pushRoot = layout.pushRoot(for: harness)
                let base = Paths.canonical(pushRoot) ?? pushRoot
                let destination = Paths.relative(from: base, to: target)
                steps.append(PushStep(harness: harness, outcome: .link(path: pushRoot + "/" + name, destination: destination)))
                present[pushRoot, default: [:]][name] = .some(target)
            }
        }
        return .steps(steps)
    }
}
