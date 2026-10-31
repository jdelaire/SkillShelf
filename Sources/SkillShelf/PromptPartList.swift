import SkillShelfCore
import SwiftUI

struct PromptPartList: View {
    @Environment(AppModel.self) private var model
    let harness: HarnessID

    var body: some View {
        @Bindable var prompts = model.prompts
        let query = model.search.trimmingCharacters(in: .whitespaces)
        let parts = prompts.parts(for: harness).filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
        let groups = Dictionary(grouping: parts, by: \.layer)
        List(selection: $prompts.selection) {
            Section("Instructions") {
                ForEach(groups[.instructions] ?? []) { part in
                    PromptPartRow(part: part).tag(part.id)
                }
            }
            if let agents = groups[.agentDefinitions], !agents.isEmpty {
                Section("Agent definitions") {
                    ForEach(agents) { part in
                        PromptPartRow(part: part).tag(part.id)
                    }
                }
            }
            Section {
                ForEach(groups[.base] ?? []) { part in
                    PromptPartRow(part: part).tag(part.id)
                }
            } header: {
                PromptBaseHeader(prompts: prompts, harness: harness)
            }
            Section {
                if let error = prompts.captureError[harness] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(groups[.capture] ?? []) { part in
                    PromptPartRow(part: part).tag(part.id)
                }
            } header: {
                PromptCaptureHeader(prompts: prompts, harness: harness)
            }
        }
        .task(id: harness) {
            let state = model.prompts
            async let base = state.loadBase(harness)
            await state.loadCaptures(harness)
            _ = await base
        }
    }
}

private struct PromptPartRow: View {
    let part: PromptPart

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch part.status {
            case .present:
                Image(systemName: "checkmark.circle")
                    .accessibilityLabel("Present")
            case .missing:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Missing")
            case .unavailable(let reason):
                Image(systemName: "minus.circle")
                    .help(reason)
                    .accessibilityLabel("Unavailable: \(reason)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(part.title)
                if !part.notes.isEmpty {
                    Text(part.notes.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PromptBaseHeader: View {
    let prompts: PromptState
    let harness: HarnessID
    @State private var retrying = false

    var body: some View {
        HStack {
            if case .loaded(let base) = prompts.base[harness] {
                Text("Base prompt @ \(base.version ?? "Unknown")")
                Spacer()
                if base.parts.contains(where: {
                    if case .unavailable(let reason) = $0.status { return reason.hasPrefix("Could not") }
                    return false
                }) {
                    Button("Retry") {
                        retrying = true
                        Task {
                            await prompts.loadBase(harness, force: true)
                            retrying = false
                        }
                    }
                    .disabled(retrying)
                    .buttonStyle(.borderless)
                }
            } else {
                Text("Base prompt")
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct PromptCaptureHeader: View {
    let prompts: PromptState
    let harness: HarnessID

    var body: some View {
        HStack {
            Text("Capture")
            Spacer()
            if prompts.capturing == harness {
                ProgressView().controlSize(.small)
            }
            Button("Capture now") {
                Task { await prompts.capture(harness) }
            }
            .buttonStyle(.borderless)
            .disabled(prompts.capturing != nil || CaptureAdapters.adapter(for: harness) == nil)
            .help(CaptureAdapters.unavailableReason(for: harness) ?? "Capture system prompts from \(harness.displayName)")
        }
    }
}
