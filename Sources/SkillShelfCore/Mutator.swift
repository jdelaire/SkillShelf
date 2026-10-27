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
        let files = FileManager.default
        var created = 0
        for step in steps {
            guard case .link(let path, let destination) = step.outcome else { continue }
            if files.fileExists(atPath: path) || (try? files.destinationOfSymbolicLink(atPath: path)) != nil {
                throw MutationError.changed(layout.display(path))
            }
            let parent = (path as NSString).deletingLastPathComponent
            try files.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: path, withDestinationPath: destination)
            created += 1
        }
        return created
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
        } else if type != .typeDirectory {
            throw MutationError.changed(item.path)
        }
    }

    private func removeLockEntry(_ key: String) throws {
        let url = URL(fileURLWithPath: layout.agentsLock)
        guard let data = try? Data(contentsOf: url),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var skills = object["skills"] as? [String: Any],
              skills.removeValue(forKey: key) != nil
        else { return }
        object["skills"] = skills
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try updated.write(to: url, options: .atomic)
    }
}
