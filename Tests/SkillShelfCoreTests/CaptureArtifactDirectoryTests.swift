import Darwin
import Foundation
import Testing
@testable import SkillShelfCore

struct CaptureArtifactDirectoryTests {
    @Test(arguments: ["home", "ancestor"], ["", "/", "/.", "//"])
    func cleanupRefusesSymlinksAnywhereInHomePath(component: String, suffix: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let target = dir.path + "/unrelated"
        let home = dir.path + "/home"
        let targetHome = target + (component == "ancestor" ? "/nested" : "")
        let transcript = targetHome + "/.claude/projects/capture/session.jsonl"
        try FileManager.default.createDirectory(
            atPath: targetHome + "/.claude/projects/capture", withIntermediateDirectories: true
        )
        try "history".write(toFile: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: home, withDestinationPath: target)
        let path = home + (component == "ancestor" ? "/nested" : "") + suffix
        #expect(throws: POSIXError.self) {
            let cleanup = try #require(try CaptureArtifactDirectory(home: .init(canonicalPath: path)))
            try cleanup.removeProject(named: "capture")
        }
        #expect((try? String(contentsOfFile: transcript, encoding: .utf8)) == "history")
    }

    @Test(arguments: [1, 256, 257])
    func cleanupBoundsDeepTreesOffMainThread(depth: Int) async throws {
        try await Task.detached {
            #expect(pthread_main_np() == 0)
            let dir = try TempDir()
            defer { dir.remove() }
            let project = dir.path + "/.claude/projects/capture"
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
            var leaf = open(project, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard leaf >= 0 else { throw POSIXError(.EIO) }
            var created = 1
            var removed = false
            defer {
                if !removed {
                    for _ in 1..<created {
                        let parent = openat(leaf, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if parent < 0 { break }
                        #expect(unlinkat(parent, "d", AT_REMOVEDIR) == 0)
                        close(leaf)
                        leaf = parent
                    }
                }
                close(leaf)
            }
            for _ in 1..<depth {
                guard mkdirat(leaf, "d", 0o700) == 0 else { throw POSIXError(.EIO) }
                let child = openat(leaf, "d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw POSIXError(.EIO) }
                close(leaf)
                leaf = child
                created += 1
            }
            let cleanup = try #require(try CaptureArtifactDirectory(home: .init(canonicalPath: dir.path)))
            do {
                try cleanup.removeProject(named: "capture")
                removed = true
                #expect(depth <= 256)
                #expect(!FileManager.default.fileExists(atPath: project))
            } catch let error as POSIXError {
                #expect(depth > 256)
                #expect(error.code == .ELOOP)
                #expect(FileManager.default.fileExists(atPath: project))
            }
        }.value
    }

    @Test func cleanupRemovesUnicodeEntryNames() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let project = dir.path + "/.claude/projects/capture"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let nested = project + "/" + String(repeating: "世", count: 80)
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try "capture".write(toFile: nested + "/café.jsonl", atomically: true, encoding: .utf8)
        let cleanup = try #require(try CaptureArtifactDirectory(home: .init(canonicalPath: dir.path)))
        try cleanup.removeProject(named: "capture")
        #expect(!FileManager.default.fileExists(atPath: project))
    }

    @Test(arguments: [".claude", ".claude/projects"], ["symlink", "directory"])
    func pinnedCleanupSurvivesAncestorSwap(ancestor: String, kind: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let projects = dir.path + "/.claude/projects"
        let unrelated = dir.path + "/unrelated/projects"
        for (parent, contents) in [(projects, "capture"), (unrelated, "history")] {
            try FileManager.default.createDirectory(atPath: parent + "/capture/nested", withIntermediateDirectories: true)
            try contents.write(toFile: parent + "/capture/nested/session.jsonl", atomically: true, encoding: .utf8)
        }
        let cleanup = try #require(try CaptureArtifactDirectory(home: .init(canonicalPath: dir.path)))
        try FileManager.default.moveItem(atPath: dir.path + "/" + ancestor, toPath: dir.path + "/parked")
        let replacement = dir.path + "/unrelated" + (ancestor == ".claude" ? "" : "/projects")
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(atPath: dir.path + "/" + ancestor, withDestinationPath: replacement)
        } else {
            try FileManager.default.moveItem(atPath: replacement, toPath: dir.path + "/" + ancestor)
        }
        try cleanup.removeProject(named: "capture")
        #expect(try String(contentsOfFile: projects + "/capture/nested/session.jsonl", encoding: .utf8) == "history")
        let pinnedProjects = dir.path + "/parked" + (ancestor == ".claude" ? "/projects" : "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: pinnedProjects).isEmpty)
    }

    @Test(arguments: ["home", "ancestor"], ["symlink", "directory"])
    func pinnedHomeSurvivesReplacementAfterIdentityCheck(component: String, kind: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        let home = dir.path + "/parent/home"
        let unrelated = dir.path + "/unrelated" + (component == "ancestor" ? "/home" : "")
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let pinned = try CaptureArtifactDirectory.Home(canonicalPath: home)
        #expect(pinned.matchesPath())
        for (parent, contents) in [(home, "capture"), (unrelated, "history")] {
            try FileManager.default.createDirectory(atPath: parent + "/.claude/projects/capture", withIntermediateDirectories: true)
            try contents.write(toFile: parent + "/.claude/projects/capture/session.jsonl", atomically: true, encoding: .utf8)
        }
        let path = dir.path + "/parent" + (component == "home" ? "/home" : "")
        try FileManager.default.moveItem(atPath: path, toPath: dir.path + "/parked")
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: dir.path + "/unrelated")
        } else {
            try FileManager.default.moveItem(atPath: dir.path + "/unrelated", toPath: path)
        }
        #expect(!pinned.matchesPath())
        let cleanup = try #require(try CaptureArtifactDirectory(home: pinned))
        try cleanup.removeProject(named: "capture")
        #expect(try String(contentsOfFile: home + "/.claude/projects/capture/session.jsonl", encoding: .utf8) == "history")
        let parked = dir.path + "/parked" + (component == "ancestor" ? "/home" : "")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parked + "/.claude/projects").isEmpty)
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
        #expect(throws: POSIXError.self) { try CaptureArtifactDirectory(home: .init(canonicalPath: home)) }
        #expect(try String(contentsOfFile: target + "/session.jsonl", encoding: .utf8) == "history")
        if kind == "file" {
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "history")
        }
    }

    @Test func missingArtifactsAreHarmless() throws {
        let dir = try TempDir()
        defer { dir.remove() }
        #expect(try CaptureArtifactDirectory(home: .init(canonicalPath: dir.path)) == nil)
        try FileManager.default.createDirectory(atPath: dir.path + "/.claude/projects/unrelated", withIntermediateDirectories: true)
        let cleanup = try #require(try CaptureArtifactDirectory(home: .init(canonicalPath: dir.path)))
        try cleanup.removeProject(named: "missing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path + "/.claude/projects") == ["unrelated"])
    }

    @Test(arguments: ["", ".", "..", "../unrelated", "/unrelated", "capture\0/unrelated"])
    func cleanupRejectsNamesOutsidePinnedDirectory(name: String) throws {
        let dir = try TempDir()
        defer { dir.remove() }
        try FileManager.default.createDirectory(atPath: dir.path + "/.claude/projects", withIntermediateDirectories: true)
        let cleanup = try #require(try CaptureArtifactDirectory(home: .init(canonicalPath: dir.path)))
        #expect(throws: POSIXError(.EINVAL)) { try cleanup.removeProject(named: name) }
        #expect(FileManager.default.fileExists(atPath: dir.path + "/.claude/projects"))
    }
}
