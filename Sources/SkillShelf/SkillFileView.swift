import AppKit
import MarkdownUI
import SkillShelfCore
import SwiftUI

struct SkillFileView: View {
    let folder: String
    @State private var loaded: Loaded?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("SKILL.md").font(.headline)
            if let loaded, loaded.folder == folder {
                Markdown(loaded.parsed.content, baseURL: URL(fileURLWithPath: folder, isDirectory: true))
                    .markdownTheme(.gitHub.text { BackgroundColor(nil) })
                    .markdownImageProvider(LocalImageProvider())
                    .markdownInlineImageProvider(LocalInlineImageProvider())
                    .textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: folder) {
            let parsed = await Self.load(folder)
            guard !Task.isCancelled else { return }
            loaded = Loaded(folder: folder, parsed: parsed)
        }
    }

    struct Loaded {
        let folder: String
        let parsed: Parsed
    }

    struct Parsed: @unchecked Sendable {
        let content: MarkdownContent
    }

    @concurrent
    static func load(_ folder: String) async -> Parsed {
        guard let data = FileManager.default.contents(atPath: folder + "/SKILL.md") else {
            return Parsed(content: MarkdownContent("_SKILL.md could not be read._"))
        }
        return Parsed(content: MarkdownContent(Frontmatter.body(String(decoding: data, as: UTF8.self))))
    }
}

struct LocalImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url, url.isFileURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: image.size.width)
        } else if let url, !url.isFileURL {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            Label(url?.lastPathComponent ?? "Image", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LocalInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        if url.isFileURL {
            guard let image = NSImage(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
            return Image(nsImage: image)
        }
        return try await DefaultInlineImageProvider.default.image(with: url, label: label)
    }
}
