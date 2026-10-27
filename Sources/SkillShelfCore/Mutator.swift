import Foundation

public enum MutationError: Error, LocalizedError {
    case changed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .changed(let path): "\(path) changed since the last scan. Refresh and try again."
        case .commandFailed(let output): output
        }
    }
}

public actor Mutator {
    private let layout: Layout
    private let runner: any CommandRunning

    public init(layout: Layout, runner: any CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    public func perform(_ option: DeleteOption) async throws {
        switch option.action {
        case .trash(let items, let lockKey):
            for item in items { try Self.verify(item) }
            let ordered = items.filter { $0.linkDestination != nil } + items.filter { $0.linkDestination == nil }
            for item in ordered {
                try Self.verify(item)
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            }
            if let lockKey { try removeLockEntry(lockKey) }
        case .uninstall(let uninstall):
            let result = try await runner.run(uninstall.tool, uninstall.arguments)
            guard result.status == 0 else {
                let message = [result.error, result.output].first { !$0.isEmpty } ?? "Exit status \(result.status)"
                throw MutationError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    public func perform(_ steps: [PushStep]) throws -> Int {
        try Self.preflightAndLink(steps)
    }

    static func preflightAndLink(_ steps: [PushStep]) throws -> Int {
        let links = steps.compactMap { step -> (path: String, destination: String, target: String)? in
            guard case .link(let path, let destination) = step.outcome else { return nil }
            return (path, destination, step.target)
        }
        for link in links { try Self.preflight(link.path, target: link.target) }
        let files = FileManager.default
        for link in links {
            try Self.preflight(link.path, target: link.target)
            try files.createDirectory(atPath: (link.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: link.path, withDestinationPath: link.destination)
            guard Paths.canonical(link.path) == link.target else {
                try? files.removeItem(atPath: link.path)
                throw MutationError.changed(link.path)
            }
        }
        return links.count
    }

    static func preflight(_ path: String, target: String) throws {
        let files = FileManager.default
        if (try? files.attributesOfItem(atPath: path)) != nil { throw MutationError.changed(path) }
        guard Paths.canonical(target) == target, files.fileExists(atPath: target + "/SKILL.md") else {
            throw MutationError.changed(target)
        }
    }

    static func verify(_ item: PathExpectation) throws {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: item.path),
              let type = attributes[.type] as? FileAttributeType
        else { throw MutationError.changed(item.path) }
        if let expected = item.linkDestination {
            guard type == .typeSymbolicLink, (try? files.destinationOfSymbolicLink(atPath: item.path)) == expected else {
                throw MutationError.changed(item.path)
            }
            return
        }
        let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard type == .typeDirectory, Paths.canonical(item.path) == item.path, number == item.fileNumber else {
            throw MutationError.changed(item.path)
        }
    }

    private func removeLockEntry(_ key: String) throws {
        let url = URL(fileURLWithPath: layout.agentsLock)
        guard let original = try? Data(contentsOf: url),
              var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var skills = object["skills"] as? [String: Any],
              skills.removeValue(forKey: key) != nil
        else { return }
        object["skills"] = skills
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard (try? Data(contentsOf: url)) == original else { throw MutationError.changed(layout.agentsLock) }
        try updated.write(to: url, options: .atomic)
    }
}
