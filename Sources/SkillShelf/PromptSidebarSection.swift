import SkillShelfCore
import SwiftUI

struct PromptSidebarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("System prompts") {
            ForEach(model.snapshot.harnesses) { harness in
                Label { Text(harness.displayName) } icon: { HarnessIcon(harness: harness) }
                    .badge(model.prompts.parts(for: harness).filter { $0.status == .present }.count)
                    .tag(SidebarItem.prompts(harness))
            }
        }
    }
}
