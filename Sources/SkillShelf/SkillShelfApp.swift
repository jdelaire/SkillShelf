import AppKit
import SwiftUI

@main
struct SkillShelfApp: App {
    @State private var model = AppModel()
    @StateObject private var updater = Updater()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("SkillShelf") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 560)
                .task { await model.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refresh() }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
