import AppKit
import MarkdownUI
import SkillShelfCore
import SwiftUI

struct PromptTextView: View {
    @Environment(AppModel.self) private var model
    let part: PromptPart
    @State private var loaded: Loaded?
    @State private var reload = 0

    var body: some View {
        let loadID = "\(part.id)#\(model.prompts.contentGeneration)#\(reload)"
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PromptTextHeader(part: part, layout: model.layout)
                Divider()
                if let loaded, loaded.id == loadID {
                    switch loaded.parsed {
                    case .rendered(_, let content):
                        Markdown(content, baseURL: baseURL)
                            .markdownTheme(.shelf)
                            .markdownImageProvider(LocalImageProvider())
                            .markdownInlineImageProvider(LocalInlineImageProvider())
                            .textSelection(.enabled)
                            .frame(maxWidth: 720, alignment: .leading)
                    case .failed(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Retry") { reload += 1 }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: loadID) {
            let text = await PromptContent.load(part, fetcher: URLSessionFetcher())
            guard !Task.isCancelled else { return }
            let parsed = await Self.parse(text)
            guard !Task.isCancelled else { return }
            loaded = Loaded(id: loadID, parsed: parsed)
        }
        .toolbar {
            ToolbarItemGroup {
                PromptActions(source: part.source, text: loaded?.id == loadID ? loaded?.parsed.text : nil)
            }
        }
    }

    private var baseURL: URL? {
        switch part.source {
        case .file(let path, _), .capture(let path): URL(fileURLWithPath: path).deletingLastPathComponent()
        case .remote(let url, _): url.deletingLastPathComponent()
        case .none: nil
        }
    }

    private struct Loaded {
        let id: String
        let parsed: Parsed
    }

    enum Parsed: @unchecked Sendable {
        case rendered(text: String, content: MarkdownContent)
        case failed(String)

        var text: String? {
            if case .rendered(let text, _) = self { return text }
            return nil
        }
    }

    @concurrent
    static func parse(_ text: PromptText) async -> Parsed {
        switch text {
        case .markdown(let text):
            return .rendered(text: text, content: MarkdownContent(text))
        case .code(let text, let language):
            var longest = 0
            var count = 0
            for byte in text.utf8 {
                count = byte == 96 ? count + 1 : 0
                longest = max(longest, count)
            }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let markdown = fence + language + "\n" + text + "\n" + fence
            return .rendered(text: text, content: MarkdownContent(markdown))
        case .failed(let reason):
            return .failed(reason)
        }
    }
}

private struct PromptTextHeader: View {
    let part: PromptPart
    let layout: SkillShelfCore.Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(part.title).font(.title2.weight(.semibold))
            switch part.source {
            case .file(let path, let key):
                Text(layout.display(path))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let key {
                    Text(key)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            case .capture(let path):
                Text(layout.display(path))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .remote(let url, _):
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .none:
                EmptyView()
            }
            if let version = part.version {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !part.notes.isEmpty {
                Text(part.notes.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct PromptActions: View {
    let source: PromptSource
    let text: String?

    var body: some View {
        if let fileURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal in Finder")
        }
        Button {
            if let openURL { NSWorkspace.shared.open(openURL) }
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        .help("Open")
        .disabled(openURL == nil)
        Button {
            if let text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        .help("Copy text")
        .disabled(text == nil)
    }

    private var fileURL: URL? {
        switch source {
        case .file(let path, _), .capture(let path): URL(fileURLWithPath: path)
        case .remote, .none: nil
        }
    }

    private var openURL: URL? {
        if case .remote(let url, _) = source { return url }
        return fileURL
    }
}
