import Darwin
import Foundation

final class CaptureArtifactDirectory {
    private let descriptor: Int32

    final class Home {
        private let path: String
        fileprivate let descriptor: Int32
        private let device: dev_t
        private let inode: ino_t

        init(canonicalPath: String) throws {
            let descriptor = try CaptureArtifactDirectory.openHome(canonicalPath)
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(descriptor)
                throw error
            }
            path = canonicalPath
            self.descriptor = descriptor
            device = info.st_dev
            inode = info.st_ino
        }

        deinit { close(descriptor) }

        func matchesPath() -> Bool {
            guard let current = try? CaptureArtifactDirectory.openHome(path) else { return false }
            defer { close(current) }
            var info = stat()
            return fstat(current, &info) == 0 && info.st_dev == device && info.st_ino == inode
        }
    }

    static func canonicalHome(_ home: String) throws -> String {
        guard home.hasPrefix("/"), !home.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        guard let resolved = realpath(home, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        guard let path = String(validatingCString: resolved) else { throw POSIXError(.EINVAL) }
        return path
    }

    init?(home: Home) throws {
        guard let claude = try Self.openDirectory(".claude", relativeTo: home.descriptor) else { return nil }
        defer { close(claude) }
        guard let projects = try Self.openDirectory("projects", relativeTo: claude) else { return nil }
        descriptor = projects
    }

    deinit { close(descriptor) }

    private static func openHome(_ home: String) throws -> Int32 {
        guard home.hasPrefix("/"), !home.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let components = home == "/" ? [] : home.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw POSIXError(.EINVAL)
        }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { if parent >= 0 { close(parent) } }
        for component in components {
            guard let child = try openDirectory(String(component), relativeTo: parent) else { throw POSIXError(.ENOENT) }
            close(parent)
            parent = child
        }
        let descriptor = parent
        parent = -1
        return descriptor
    }

    func removeProject(named name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        guard let root = try Self.openEntry(Array(name.utf8CString), relativeTo: descriptor) else { return }
        var stack = [root]
        while let directory = stack.last {
            errno = 0
            guard let entry = readdir(directory.stream) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try directory.name.withUnsafeBufferPointer {
                    guard unlinkat(directory.parent, $0.baseAddress!, AT_REMOVEDIR) == 0 || errno == ENOENT else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                stack.removeLast()
                continue
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name: [CChar]? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { name in
                    guard strcmp(name, ".") != 0, strcmp(name, "..") != 0 else { return nil }
                    return Array(UnsafeBufferPointer(start: name, count: capacity))
                }
            }
            guard let name, let child = try Self.openEntry(name, relativeTo: dirfd(directory.stream)) else { continue }
            guard stack.count < 256 else { throw POSIXError(.ELOOP) }
            stack.append(child)
        }
    }

    private static func openDirectory(_ path: String, relativeTo parent: Int32) throws -> Int32? {
        let descriptor = openat(parent, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private static func openEntry(_ name: [CChar], relativeTo parent: Int32) throws -> Directory? {
        try name.withUnsafeBufferPointer { try openEntry($0.baseAddress!, name: name, relativeTo: parent) }
    }

    private static func openEntry(_ pointer: UnsafePointer<CChar>, name: [CChar], relativeTo parent: Int32) throws -> Directory? {
        let descriptor = openat(parent, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            guard errno == ENOTDIR || errno == ELOOP else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard unlinkat(parent, pointer, 0) == 0 || errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return nil
        }
        guard let directory = fdopendir(descriptor) else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        return Directory(stream: directory, parent: parent, name: name)
    }

    private final class Directory {
        let stream: UnsafeMutablePointer<DIR>
        let parent: Int32
        let name: [CChar]

        init(stream: UnsafeMutablePointer<DIR>, parent: Int32, name: [CChar]) {
            self.stream = stream
            self.parent = parent
            self.name = name
        }

        deinit { closedir(stream) }
    }
}
