import Darwin
import Foundation
import Synchronization

public enum CaptureError: Error, Equatable, LocalizedError {
    case sandboxUnavailable
    case busy
    case notInstalled
    case noRequest(version: String?)

    public var errorDescription: String? {
        switch self {
        case .sandboxUnavailable:
            "Network sandbox unavailable. Capture did not run."
        case .busy:
            "Capture already running"
        case .notInstalled:
            "Not installed"
        case .noRequest(let version):
            "The harness made no request to the capture endpoint. Its redirect setting may have changed in \(version ?? "this version")."
        }
    }
}

public protocol CaptureProcessHandle: Sendable {
    var pid: pid_t { get }
    func terminate() async
    func exitStatus() async -> Int32
    func diagnostics() async -> (stdout: String, stderr: String)
}

public protocol CaptureProcessLaunching: Sendable {
    func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle
}

public enum CaptureEnvironment {
    public static func sanitized(_ base: [String: String]) -> [String: String] {
        let prefixes = ["ANTHROPIC_", "OPENAI_", "GOOGLE_", "XAI_"]
        let exact: Set<String> = [
            "CLAUDE_CODE_OAUTH_TOKEN", "GEMINI_API_KEY", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"
        ]
        return base.filter { key, _ in
            let name = key.uppercased()
            return !exact.contains(name) && !prefixes.contains { name.hasPrefix($0) }
        }
    }
}

public struct SpawnLauncher: CaptureProcessLaunching {
    public init() {}

    public func launch(argv: [String], environment: [String: String], cwd: String) throws -> any CaptureProcessHandle {
        guard let executable = argv.first, !executable.isEmpty,
              !argv.contains(where: { $0.utf8.contains(0) }), !cwd.utf8.contains(0),
              environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
              }) else { throw POSIXError(.EINVAL) }

        var output = try makePipe()
        defer { output.forEach { if $0 >= 0 { close($0) } } }
        var error = try makePipe()
        defer { error.forEach { if $0 >= 0 { close($0) } } }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO))
        for descriptor in output + error {
            try check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, cwd))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, cwd))
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        let arguments = try cStrings(argv)
        defer { arguments.forEach { free($0) } }
        let variables = try cStrings(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer { variables.forEach { free($0) } }
        var pid: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { arguments in
            variables.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, executable, &actions, &attributes, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        try check(result)
        close(output[1])
        output[1] = -1
        close(error[1])
        error[1] = -1
        let handle = SpawnHandle(pid: pid, stdout: output[0], stderr: error[0])
        output[0] = -1
        error[0] = -1
        return handle
    }

    private func check(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    private func makePipe() throws -> [Int32] {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            for index in descriptors.indices {
                if descriptors[index] <= STDERR_FILENO {
                    let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
                    guard replacement >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    close(descriptors[index])
                    descriptors[index] = replacement
                } else if fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) < 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return descriptors
        } catch {
            descriptors.forEach { close($0) }
            throw error
        }
    }

    private func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                pointers.forEach { free($0) }
                throw POSIXError(.ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }
}

private final class SpawnHandle: CaptureProcessHandle {
    let pid: pid_t
    private let exit: Task<Int32, Never>
    private let output: Task<String, Never>
    private let error: Task<String, Never>
    private let termination = Mutex<Task<Void, Never>?>(nil)

    init(pid: pid_t, stdout: Int32, stderr: Int32) {
        self.pid = pid
        output = Self.drain(stdout)
        error = Self.drain(stderr)
        exit = Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    var result: pid_t
                    repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
                    guard result == pid else {
                        continuation.resume(returning: -1)
                        return
                    }
                    let signal = status & 0x7f
                    continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
                }
            }
        }
    }

    func exitStatus() async -> Int32 {
        await exit.value
    }

    func diagnostics() async -> (stdout: String, stderr: String) {
        await (output.value, error.value)
    }

    func terminate() async {
        let task = termination.withLock { task in
            if let task { return task }
            let cleanup = Task.detached { [pid, exit, output, error] in
                if Self.groupExists(pid) {
                    kill(-pid, SIGTERM)
                    let deadline = ContinuousClock.now + .seconds(3)
                    while Self.groupExists(pid), ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    if Self.groupExists(pid) { kill(-pid, SIGKILL) }
                }
                _ = await exit.value
                while Self.groupExists(pid) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                _ = await (output.value, error.value)
            }
            task = cleanup
            return cleanup
        }
        await task.value
    }

    private static func groupExists(_ pid: pid_t) -> Bool {
        kill(-pid, 0) == 0 || errno != ESRCH
    }

    private static func drain(_ descriptor: Int32) -> Task<String, Never> {
        Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    defer { close(descriptor) }
                    var tail = CaptureTail()
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        buffer.withUnsafeBytes { tail.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                    }
                    continuation.resume(returning: tail.text)
                }
            }
        }
    }
}

private struct CaptureTail {
    private var bytes = [UInt8](repeating: 0, count: 262_144)
    private var offset = 0
    private var count = 0

    mutating func append(_ chunk: UnsafeRawBufferPointer) {
        let first = min(chunk.count, bytes.count - offset)
        bytes.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: offset).copyMemory(from: chunk.baseAddress!, byteCount: first)
            if first < chunk.count {
                destination.baseAddress!.copyMemory(from: chunk.baseAddress!.advanced(by: first), byteCount: chunk.count - first)
            }
        }
        offset = (offset + chunk.count) % bytes.count
        count = min(count + chunk.count, bytes.count)
    }

    var text: String {
        if count < bytes.count { return String(decoding: bytes.prefix(count), as: UTF8.self) }
        return String(decoding: bytes[offset...] + bytes[..<offset], as: UTF8.self)
    }
}
