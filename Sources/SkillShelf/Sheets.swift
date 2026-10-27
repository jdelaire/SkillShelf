import SkillShelfCore
import SwiftUI

struct DeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: DeleteRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \(request.entry.name)").font(.title3.weight(.semibold))
            switch request.result {
            case .blocked(let reason):
                Text(reason).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            case .options(let options):
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.detail)
                        PathList(paths: option.affectedPaths.map(model.layout.display))
                        Button(role: .destructive) {
                            Task { await model.perform(option) }
                        } label: {
                            Text(option.title)
                        }
                        .disabled(model.isWorking)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct PushSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PushRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Push \(request.entry.name) to all harnesses").font(.title3.weight(.semibold))
            switch request.result {
            case .blocked(let reason):
                Text(reason).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            case .steps(let steps):
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(steps) { step in
                        GridRow {
                            Text(step.harness.displayName).fontWeight(.medium)
                            outcome(step.outcome)
                        }
                    }
                }
                let links = steps.filter { if case .link = $0.outcome { true } else { false } }
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(links.isEmpty ? "Nothing to do" : "Create \(links.count) link\(links.count == 1 ? "" : "s")") {
                        Task { await model.push(steps) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(links.isEmpty || model.isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    @ViewBuilder
    private func outcome(_ outcome: PushStep.Outcome) -> some View {
        switch outcome {
        case .present(let via):
            Label("Already there via \(via)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .link(let path, let destination):
            Label {
                Text("Link \(model.layout.display(path)) → \(destination)")
                    .font(.callout.monospaced())
            } icon: {
                Image(systemName: "link.badge.plus").foregroundStyle(.blue)
            }
        case .conflict(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct PathList: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(paths, id: \.self) { path in
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}
