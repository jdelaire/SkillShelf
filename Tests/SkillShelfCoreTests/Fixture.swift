import Foundation
@testable import SkillShelfCore

struct Fixture {
    let home: String
    let layout: Layout

    init() throws {
        let raw = NSTemporaryDirectory() + "skillshelf-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        layout = Layout(home: raw)
        home = layout.home
    }

    func skill(_ relative: String, name: String? = nil) throws {
        let folder = layout.path(relative)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let title = name ?? (relative as NSString).lastPathComponent
        try "---\nname: \(title)\ndescription: About \(title)\n---\nBody\n".write(
            toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8
        )
    }

    func link(_ relative: String, to destination: String) throws {
        let path = layout.path(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    func write(_ relative: String, _ text: String) throws {
        let path = layout.path(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func snapshot(_ inputs: SkillScanner.Inputs = .init()) -> Snapshot {
        SkillScanner.snapshot(layout: layout, inputs: inputs, generation: 1)
    }

    func entry(_ snapshot: Snapshot, _ relative: String) -> SkillEntry? {
        snapshot.entries.first { $0.entryPath == layout.path(relative) }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: home)
    }
}
