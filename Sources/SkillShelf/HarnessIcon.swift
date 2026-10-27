import AppKit
import SkillShelfCore
import SwiftUI

struct HarnessIcon: View {
    let harness: HarnessID

    var body: some View {
        if let image = HarnessIcons.shared.image(for: harness) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal")
        }
    }
}

@MainActor
final class HarnessIcons {
    static let shared = HarnessIcons()
    private var cache: [HarnessID: NSImage?] = [:]

    func image(for harness: HarnessID) -> NSImage? {
        if let cached = cache[harness] { return cached }
        let image = Self.bundleIDs(harness)
            .lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[harness] = image
        return image
    }

    private static func bundleIDs(_ harness: HarnessID) -> [String] {
        switch harness {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .antigravity: ["com.google.antigravity"]
        case .opencode, .grok, .muse: []
        }
    }
}
