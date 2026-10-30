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
        let drainDeadline = CaptureDrainDeadline()
        output = Self.drain(stdout, deadline: drainDeadline)
        error = Self.drain(stderr, deadline: drainDeadline)
        exit = Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    var result: pid_t
                    repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
                    drainDeadline.set(ContinuousClock.now + .seconds(2))
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
                let descendants = Self.descendants(of: pid)
                Self.signal(SIGTERM, group: pid, descendants: descendants)
                let deadline = ContinuousClock.now + .seconds(3)
                while Self.processesExist(group: pid, descendants: descendants), ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if Self.processesExist(group: pid, descendants: descendants) {
                    Self.signal(SIGKILL, group: pid, descendants: descendants)
                }
                _ = await exit.value
                let cleanupDeadline = ContinuousClock.now + .seconds(2)
                while Self.processesExist(group: pid, descendants: descendants), ContinuousClock.now < cleanupDeadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                _ = await (output.value, error.value)
            }
            task = cleanup
            return cleanup
        }
        await task.value
    }

    private static func signal(_ signal: Int32, group: pid_t, descendants: [pid_t]) {
        for descendant in descendants.reversed() { kill(descendant, signal) }
        kill(-group, signal)
    }

    private static func processesExist(group: pid_t, descendants: [pid_t]) -> Bool {
        if kill(-group, 0) == 0 || errno != ESRCH { return true }
        return descendants.contains { kill($0, 0) == 0 || errno != ESRCH }
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0 else { return [] }
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            let result = processes.withUnsafeMutableBytes { buffer in
                size = buffer.count
                return sysctl(&query, UInt32(query.count), buffer.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return []
            }
            var children: [pid_t: [pid_t]] = [:]
            for process in processes.prefix(size / stride) where process.kp_proc.p_pid > 0 {
                children[process.kp_eproc.e_ppid, default: []].append(process.kp_proc.p_pid)
            }
            var visited: Set<pid_t> = [pid]
            var pending = [pid]
            var descendants: [pid_t] = []
            while let parent = pending.popLast() {
                for child in children[parent, default: []] where visited.insert(child).inserted {
                    descendants.append(child)
                    pending.append(child)
                }
            }
            return descendants
        }
        return []
    }

    private static func drain(_ descriptor: Int32, deadline: CaptureDrainDeadline) -> Task<String, Never> {
        Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    defer { close(descriptor) }
                    var tail = CaptureTail()
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    while !deadline.expired {
                        var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                        let ready = poll(&descriptorState, 1, 20)
                        if ready < 0 && errno == EINTR { continue }
                        if ready == 0 { continue }
                        guard ready > 0 else { break }
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

private final class CaptureDrainDeadline: Sendable {
    private let deadline = Mutex<ContinuousClock.Instant?>(nil)

    func set(_ value: ContinuousClock.Instant) {
        deadline.withLock { $0 = value }
    }

    var expired: Bool {
        deadline.withLock { $0.map { ContinuousClock.now >= $0 } ?? false }
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
        let decoded = count < bytes.count
            ? String(decoding: bytes.prefix(count), as: UTF8.self)
            : String(decoding: bytes[offset...] + bytes[..<offset], as: UTF8.self)
        guard decoded.utf8.count > bytes.count else { return decoded }
        let suffix = decoded.utf8.suffix(bytes.count).drop(while: { $0 & 0xc0 == 0x80 })
        return String(decoding: suffix, as: UTF8.self)
    }
}
