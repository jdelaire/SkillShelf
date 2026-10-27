import SkillShelfCore
import SwiftUI

struct SkillDetail: View {
    @Environment(AppModel.self) private var model
    let row: HarnessRow

    var body: some View {
        let entry = row.entry
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name).font(.title2.weight(.semibold))
                    KindBadge(row: row)
                }
                if let reason = entry.lockReason {
                    Label(reason, systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !entry.description.isEmpty {
                    Text(entry.description)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    PathRow(label: "Path", value: model.layout.display(entry.entryPath))
                    if let destination = entry.linkDestination {
                        PathRow(label: "Links to", value: destination)
                    }
                    if entry.resolvedPath != entry.entryPath {
                        PathRow(label: "Folder", value: entry.resolvedPath.map(model.layout.display) ?? "Missing")
                    }
                    if case .plugin(let plugin) = entry.protection {
                        PathRow(label: "Plugin", value: plugin.id)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Seen by").font(.headline)
                    FlowChips(items: model.snapshot.seenBy(entry))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PathRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}

struct FlowChips: View {
    let items: [(HarnessID, Bool)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { harness, thirdParty in
                Label { Text(thirdParty ? "\(harness.displayName)*" : harness.displayName) } icon: { HarnessIcon(harness: harness) }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .help(thirdParty ? "Only if third-party skills are turned on in \(harness.displayName)." : "")
            }
            if items.isEmpty {
                Text("No harness").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
