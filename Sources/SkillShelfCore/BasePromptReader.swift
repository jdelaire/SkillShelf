import Foundation

public protocol PromptFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

public struct URLSessionFetcher: PromptFetching {
    public init() {}

    public func data(from url: URL) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public struct BasePrompts: Sendable {
    public let version: String?
    public let parts: [PromptPart]
}

public enum BasePromptReader {
    @concurrent
    public static func read(
        harness: HarnessID,
        layout: Layout,
        runner: any CommandRunning,
        fetcher: any PromptFetching,
        cacheRoot: String = NSHomeDirectory() + "/Library/Caches/SkillShelf/prompts",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> BasePrompts {
        let installedVersion: String
        do {
            let result = try await runner.run(harness == .antigravity ? "agy" : harness.rawValue, ["--version"])
            guard result.status == 0, let parsed = version(from: result.output) else {
                return unavailable(
                    harness: harness,
                    reason: "Could not read version: " + firstLine(result.error, result.output)
                )
            }
            installedVersion = parsed
        } catch {
            return unavailable(harness: harness, reason: "Could not read version: " + firstLine(error.localizedDescription))
        }

        switch harness {
        case .codex:
            return codex(layout: layout, version: installedVersion, cacheRoot: cacheRoot, environment: environment)
        case .opencode:
            return await openCode(version: installedVersion, fetcher: fetcher, cacheRoot: cacheRoot)
        default:
            return unavailable(harness: harness, version: installedVersion, reason: "Closed source. Use Capture.")
        }
    }

    public static func version(from output: String) -> String? {
        guard let range = output.range(
            of: #"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?"#,
            options: .regularExpression
        ) else { return nil }
        return String(output[range])
    }

    public static func openCodeListURL(version: String) -> URL {
        var components = URLComponents(string: "https://api.github.com/repos/anomalyco/opencode/contents/packages/opencode/src/session/prompt")!
        components.queryItems = [URLQueryItem(name: "ref", value: "v" + version)]
        return components.url!
    }

    public static func openCodeFileURL(version: String, name: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/anomalyco/opencode")!
            .appendingPathComponent("v" + version)
            .appendingPathComponent("packages/opencode/src/session/prompt")
            .appendingPathComponent(name)
    }

    public static func codexFallbackURL(version: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/openai/codex")!
            .appendingPathComponent("rust-v" + version)
            .appendingPathComponent("codex-rs/models-manager/prompt.md")
    }

    public static func cachePath(cacheRoot: String, harness: HarnessID, version: String, file: String) -> String {
        URL(fileURLWithPath: (cacheRoot as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(harness.rawValue)
            .appendingPathComponent(version)
            .appendingPathComponent(file)
            .path
    }

    private static func codex(layout: Layout, version: String, cacheRoot: String, environment: [String: String]) -> BasePrompts {
        let home = InstructionReader.codexHome(layout: layout, environment: environment)
        let path = home + "/models_cache.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = cache["models"] as? [[String: Any]] {
            let config = (try? String(contentsOfFile: home + "/config.toml", encoding: .utf8)) ?? ""
            let configured = TOMLKeys(config).string("model")
            let parts = models.compactMap { model -> PromptPart? in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return PromptPart(
                    harness: .codex, layer: .base, title: slug,
                    source: .file(path: path, key: "models." + slug), status: .present,
                    version: version, notes: slug == configured ? ["Configured model"] : []
                )
            }.sorted { $0.title == configured && $1.title != configured }
            if !parts.isEmpty { return BasePrompts(version: version, parts: parts) }
        }
        return BasePrompts(version: version, parts: [PromptPart(
            harness: .codex, layer: .base, title: "prompt.md",
            source: .remote(
                url: codexFallbackURL(version: version),
                cache: cachePath(cacheRoot: cacheRoot, harness: .codex, version: version, file: "prompt.md")
            ),
            status: .present, version: version
        )])
    }

    private struct ListingEntry: Decodable {
        let name: String
        let type: String
    }

    private static func openCode(version: String, fetcher: any PromptFetching, cacheRoot: String) async -> BasePrompts {
        let index = URL(fileURLWithPath: cachePath(cacheRoot: cacheRoot, harness: .opencode, version: version, file: "index.json"))
        let names: [String]
        if let data = try? Data(contentsOf: index), let cached = try? JSONDecoder().decode([String].self, from: data) {
            names = promptNames(cached)
        } else {
            do {
                let data = try await fetcher.data(from: openCodeListURL(version: version))
                let entries = try JSONDecoder().decode([ListingEntry].self, from: data)
                names = promptNames(entries.filter { $0.type == "file" }.map(\.name))
                let encoded = try JSONEncoder().encode(names)
                try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: index, options: .atomic)
            } catch {
                return unavailable(harness: .opencode, version: version, reason: "Could not list prompts: " + error.localizedDescription)
            }
        }
        return BasePrompts(version: version, parts: names.map { name in
            PromptPart(
                harness: .opencode, layer: .base, title: name,
                source: .remote(
                    url: openCodeFileURL(version: version, name: name),
                    cache: cachePath(cacheRoot: cacheRoot, harness: .opencode, version: version, file: name)
                ),
                status: .present, version: version
            )
        })
    }

    private static func promptNames(_ names: [String]) -> [String] {
        Array(Set(names.filter { $0.hasSuffix(".txt") && ($0 as NSString).lastPathComponent == $0 })).sorted()
    }

    private static func firstLine(_ outputs: String...) -> String {
        for output in outputs {
            if let line = output.split(whereSeparator: \.isNewline).first {
                return String(line)
            }
        }
        return "Unknown version"
    }

    private static func unavailable(harness: HarnessID, version: String? = nil, reason: String) -> BasePrompts {
        BasePrompts(version: version, parts: [PromptPart(
            harness: harness, layer: .base, title: "Base prompt", source: .none,
            status: .unavailable(reason), version: version
        )])
    }
}
