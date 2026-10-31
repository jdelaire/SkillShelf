import Darwin
import Foundation
import Testing
@testable import SkillShelfCore

struct CaptureArtifactDirectoryTests {
    @Test(arguments: [".claude", ".claude/projects"])
    func pinnedCleanupSurvivesAncestorSwap(ancestor: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let projects = dir.path + "/.claude/projects"
        let unrelated = dir.path + "/unrelated/projects"
        for (parent, contents) in [(projects, "capture"), (unrelated, "history")] {
            try FileManager.default.createDirectory(atPath: parent + "/capture/nested", withIntermediateDirectories: true)
            try contents.write(toFile: parent + "/capture/nested/session.jsonl", atomically: true, encoding: .utf8)
        }
        let cleanup = try #require(try CaptureArtifactDirectory(home: dir.path))
        try FileManager.default.moveItem(atPath: dir.path + "/" + ancestor, toPath: dir.path + "/parked")
        try FileManager.default.createSymbolicLink(
            atPath: dir.path + "/" + ancestor,
            withDestinationPath: dir.path + "/unrelated" + (ancestor == ".claude" ? "" : "/projects")
        )
        try cleanup.removeProject(named: "capture")
        #expect(try String(contentsOfFile: unrelated + "/capture/nested/session.jsonl", encoding: .utf8) == "history")
        let pinnedProjects = dir.path + "/parked" + (ancestor == ".claude" ? "/projects" : "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: pinnedProjects).isEmpty)
    }

    @Test(arguments: ["home", ".claude", ".claude/projects"], ["symlink", "file"])
    func cleanupRefusesUnsafeParent(component: String, kind: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let home = dir.path + "/home"
        let target = dir.path + "/unrelated"
        try FileManager.default.createDirectory(atPath: home + "/.claude/projects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "history".write(toFile: target + "/session.jsonl", atomically: true, encoding: .utf8)
        let path = component == "home" ? home : home + "/" + component
        try FileManager.default.removeItem(atPath: path)
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        } else {
            try "history".write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(throws: POSIXError.self) { try CaptureArtifactDirectory(home: home) }
        #expect(try String(contentsOfFile: target + "/session.jsonl", encoding: .utf8) == "history")
        if kind == "file" {
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "history")
        }
    }

    @Test func missingArtifactsAreHarmless() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        #expect(try CaptureArtifactDirectory(home: dir.path) == nil)
        try FileManager.default.createDirectory(atPath: dir.path + "/.claude/projects/unrelated", withIntermediateDirectories: true)
        let cleanup = try #require(try CaptureArtifactDirectory(home: dir.path))
        try cleanup.removeProject(named: "missing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path + "/.claude/projects") == ["unrelated"])
    }

    @Test(arguments: ["", ".", "..", "../unrelated", "/unrelated", "capture\0/unrelated"])
    func cleanupRejectsNamesOutsidePinnedDirectory(name: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        try FileManager.default.createDirectory(atPath: dir.path + "/.claude/projects", withIntermediateDirectories: true)
        let cleanup = try #require(try CaptureArtifactDirectory(home: dir.path))
        #expect(throws: POSIXError(.EINVAL)) { try cleanup.removeProject(named: name) }
        #expect(FileManager.default.fileExists(atPath: dir.path + "/.claude/projects"))
    }
}
