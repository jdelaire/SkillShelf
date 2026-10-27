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
                    ForEach(HarnessID.allCases) { harness in
                        Label(harness.displayName, systemImage: "shippingbox")
                            .badge(model.count(for: harness))
                            .tag(SidebarItem.harness(harness))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            SkillTable()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        } detail: {
            if let row = model.selectedRow {
                SkillDetail(row: row)
            } else {
                ContentUnavailableView("No skill selected", systemImage: "sparkles")
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search skills")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
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
            .background(color.opacity(0.15), in: Capsule())
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
        if row.thirdParty { return .gray }
        switch entry.protection {
        case .builtIn, .managed: return .gray
        case .plugin: return .purple
        case .none: return entry.isSymlink ? .blue : .green
        }
    }
}
