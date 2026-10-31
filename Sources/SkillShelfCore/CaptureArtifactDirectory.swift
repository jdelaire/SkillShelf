import Darwin
import Foundation

final class CaptureArtifactDirectory {
    private let descriptor: Int32

    init?(home: String) throws {
        guard home.hasPrefix("/"), !home.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        guard let home = try Self.openDirectory(home, relativeTo: AT_FDCWD) else { return nil }
        defer { close(home) }
        guard let claude = try Self.openDirectory(".claude", relativeTo: home) else { return nil }
        defer { close(claude) }
        guard let projects = try Self.openDirectory("projects", relativeTo: claude) else { return nil }
        descriptor = projects
    }

    deinit { close(descriptor) }

    func removeProject(named name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw POSIXError(.EINVAL)
        }
        try name.withCString { try Self.removeEntry($0, relativeTo: descriptor) }
    }

    private static func openDirectory(_ path: String, relativeTo parent: Int32) throws -> Int32? {
        let descriptor = openat(parent, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private static func removeEntry(_ name: UnsafePointer<CChar>, relativeTo parent: Int32) throws {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            guard errno == ENOTDIR || errno == ELOOP else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        guard let directory = fdopendir(descriptor) else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            try withUnsafePointer(to: &entry.pointee.d_name) {
                try $0.withMemoryRebound(to: CChar.self, capacity: capacity) { name in
                    guard strcmp(name, ".") != 0, strcmp(name, "..") != 0 else { return }
                    try removeEntry(name, relativeTo: descriptor)
                }
            }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
