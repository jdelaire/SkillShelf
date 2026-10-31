import SkillShelfCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.sidebar) {
                Label("All locations", systemImage: "folder")
                    .badge(model.snapshot.entries.count)
                    .tag(SidebarItem.all)
                Section("Harnesses") {
                    ForEach(model.snapshot.harnesses) { harness in
                        Label { Text(harness.displayName) } icon: { HarnessIcon(harness: harness) }
                            .badge(model.count(for: harness))
                            .tag(SidebarItem.harness(harness))
                    }
                }
                PromptSidebarSection()
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            Group {
                if case .prompts(let harness) = model.sidebar {
                    PromptPartList(harness: harness)
                } else {
                    SkillTable()
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            if case .prompts(let harness) = model.sidebar {
                if let id = model.prompts.selection, let part = model.prompts.part(id: id), part.harness == harness {
                    PromptTextView(part: part)
                } else {
                    ContentUnavailableView("No prompt selected", systemImage: "text.alignleft")
                }
            } else if let row = model.selectedRow {
                SkillDetail(row: row)
            } else {
                ContentUnavailableView("No skill selected", systemImage: "sparkles")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                .disabled(model.isScanning)
                if case .prompts = model.sidebar {
                    SearchField(text: $model.search, prompt: "Search prompts")
                        .frame(width: 220)
                } else {
                    SkillActions(entry: model.selectedRow?.entry)
                    SearchField(text: $model.search, prompt: "Search skills")
                        .frame(width: 220)
                }
            }
        }
        .sheet(item: $model.deleteRequest) { DeleteSheet(request: $0) }
        .sheet(item: $model.pushRequest) { PushSheet(request: $0) }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SkillTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Table(model.rows, selection: $model.selection) {
                TableColumn("Name") { row in
                    HStack(spacing: 6) {
                        Text(row.entry.name)
                        if let reason = row.entry.lockReason {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help(reason)
                        }
                        if row.duplicate {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Another skill with this folder name is visible to this harness.")
                        }
                    }
                }
                TableColumn("Location") { row in
                    Text(model.layout.display(row.entry.root.path))
                        .foregroundStyle(.secondary)
                        .help(row.entry.entryPath)
                }
                TableColumn("Kind") { row in
                    KindBadge(row: row)
                }
                .width(min: 90, ideal: 110)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let entry = model.snapshot.entry(id: id) {
                    SkillMenuItems(entry: entry)
                }
            }
            if let note = statusLine {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private var statusLine: String? {
        let parts = [model.message] + model.snapshot.notes.map(Optional.some)
        let text = parts.compactMap { $0 }.joined(separator: "  ·  ")
        return text.isEmpty ? nil : text
    }
}

struct KindBadge: View {
    let row: HarnessRow

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        let entry = row.entry
        if entry.isBroken { return "Broken link" }
        if row.thirdParty { return "Third-party" }
        switch entry.protection {
        case .builtIn: return "Built-in"
        case .managed: return "Managed"
        case .plugin: return "Plugin"
        case .none: return entry.isSymlink ? "Link" : "Folder"
        }
    }

    private var color: Color {
        let entry = row.entry
        if entry.isBroken { return .red }
        if row.thirdParty { return .secondary }
        switch entry.protection {
        case .builtIn, .managed: return .secondary
        case .plugin: return .purple
        case .none: return entry.isSymlink ? .blue : .green
        }
    }
}

struct SkillActions: View {
    @Environment(AppModel.self) private var model
    let entry: SkillEntry?

    var body: some View {
        Button {
            if let entry { model.requestPush(entry) }
        } label: {
            Label("Push to all harnesses", systemImage: "square.and.arrow.up.on.square")
        }
        .help("Push to all harnesses")
        .disabled(entry == nil || model.isWorking)
        Button {
            if let entry { model.requestDelete(entry) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .help(entry?.lockReason ?? "Delete (⌘⌫)")
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(entry == nil || entry?.isDeletable == false || model.isWorking)
        Menu {
            if let entry {
                Button("Reveal in Finder") { model.reveal(entry) }
                Button("Open SKILL.md") { model.openSkillFile(entry) }
                    .disabled(entry.isBroken)
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More")
        .disabled(entry == nil)
    }
}

struct SkillMenuItems: View {
    @Environment(AppModel.self) private var model
    let entry: SkillEntry

    var body: some View {
        Button("Push to All Harnesses") { model.requestPush(entry) }
            .disabled(model.isWorking)
        Button("Delete…", role: .destructive) { model.requestDelete(entry) }
            .disabled(!entry.isDeletable || model.isWorking)
        Divider()
        Button("Reveal in Finder") { model.reveal(entry) }
        Button("Open SKILL.md") { model.openSkillFile(entry) }
            .disabled(entry.isBroken)
    }
}
