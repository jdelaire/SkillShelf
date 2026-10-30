import Darwin
import Foundation
@testable import SkillShelfCore

struct StubRunner: CommandRunning {
    let result: CommandResult

    init(output: String, error: String = "", status: Int32 = 0) {
        result = CommandResult(status: status, output: output, error: error)
    }

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        result
    }
}

struct FailingFetcher: PromptFetching {
    func data(from url: URL) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

actor CountingFetcher: PromptFetching {
    private(set) var count = 0

    func data(from url: URL) async throws -> Data {
        count += 1
        return Data()
    }
}

actor StubFetcher: PromptFetching {
    let response: Data
    private(set) var urls: [URL] = []

    init(_ response: String) {
        self.response = Data(response.utf8)
    }

    func data(from url: URL) async throws -> Data {
        urls.append(url)
        return response
    }
}

actor RecordingRunner: CommandRunning {
    private(set) var calls: [(String, [String])] = []

    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        calls.append((tool, arguments))
        return CommandResult(status: 0, output: "1.2.3", error: "")
    }
}

struct ThrowingRunner: CommandRunning {
    func run(_ tool: String, _ arguments: [String]) async throws -> CommandResult {
        throw CommandError.toolNotFound(tool)
    }
}

func withListener<T>(
    _ format: CaptureFormat, limits: CaptureLimits = .standard,
    _ body: (CaptureListener, UInt16) async throws -> T
) async throws -> T {
    let listener = CaptureListener(format: format, limits: limits)
    do {
        let port = try await listener.start()
        let result = try await body(listener, port)
        await listener.stop()
        return result
    } catch {
        await listener.stop()
        throw error
    }
}

func collectedRequests(_ listener: CaptureListener) async -> [CapturedRequest] {
    var result: [CapturedRequest] = []
    for await request in listener.requests { result.append(request) }
    return result
}

func rawPost(port: UInt16, headers: [String], body: Data) async throws -> Int {
    var data = Data((["POST /r HTTP/1.1", "Host: 127.0.0.1", "Content-Length: \(body.count)"] + headers).joined(separator: "\r\n").utf8)
    data.append(Data("\r\n\r\n".utf8))
    data.append(body)
    let response = try await rawExchange(port: port, data: data)
    guard let status = response.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
        throw URLError(.badServerResponse)
    }
    return status
}

func rawExchange(port: UInt16, data: Data) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let socket = try openIdleConnection(port: port)
                defer { close(socket) }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        offset += count
                    }
                }
                var response = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = recv(socket, &buffer, buffer.count, 0)
                    if count < 0 && errno == EINTR { continue }
                    if count == 0 { break }
                    guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    response.append(contentsOf: buffer.prefix(count))
                    if let boundary = response.range(of: Data("\r\n\r\n".utf8)) {
                        let headers = String(decoding: response[..<boundary.lowerBound], as: UTF8.self)
                        let length = headers.components(separatedBy: "\r\n")
                            .first { $0.lowercased().hasPrefix("content-length:") }?
                            .split(separator: ":", maxSplits: 1).last?
                            .trimmingCharacters(in: .whitespaces)
                        if let length, let count = Int(length), response.count - boundary.upperBound >= count { break }
                    }
                }
                continuation.resume(returning: String(decoding: response, as: UTF8.self))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

func openIdleConnection(port: UInt16) throws -> Int32 {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw POSIXError(.EIO) }
    do {
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = ipv4Address(host: "127.0.0.1", port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return socket
    } catch {
        close(socket)
        throw error
    }
}

private func ipv4Address(host: String, port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    host.withCString { _ = inet_pton(AF_INET, $0, &address.sin_addr) }
    return address
}

enum LocalAddresses {
    static func nonLoopbackIPv4() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var addresses: Set<String> = []
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var bytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
                var value = ipv4.pointee.sin_addr
                _ = inet_ntop(AF_INET, &value, &bytes, socklen_t(bytes.count))
            }
            addresses.insert(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return addresses.sorted()
    }
}

enum TCPProbe {
    static func connects(host: String, port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else { return false }
        var address = ipv4Address(host: host, port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, 1000) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: error))
        return getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }
}

func runShell(_ command: String, sandboxPort: UInt16? = nil, unixSockets: [String] = []) throws -> String {
    try runCaptureCommand(["/bin/sh", "-c", command], sandboxPort: sandboxPort, unixSockets: unixSockets)
}

func runProbe(_ url: String, sandboxPort: UInt16? = nil) throws -> String {
    let sibling = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?
        .bundleURL.deletingLastPathComponent().appendingPathComponent("SandboxProbe")
    let fallback = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/SandboxProbe")
    let binary = sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil } ?? fallback
    return try runCaptureCommand([binary.path, url], sandboxPort: sandboxPort)
}

private func runCaptureCommand(_ argv: [String], sandboxPort: UInt16?, unixSockets: [String] = []) throws -> String {
    let command = try sandboxPort.map { try CaptureSandbox.wrap(argv, port: $0, unixSockets: unixSockets) } ?? argv
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    process.environment = CaptureEnvironment.sanitized(ProcessInfo.processInfo.environment)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct TempDir {
    let path: String

    init() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("ss-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let canonical = realpath(directory.path, nil) else { throw POSIXError(.EIO) }
        defer { free(canonical) }
        path = String(cString: canonical)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

func waitForFile(_ path: String, timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while !FileManager.default.fileExists(atPath: path) {
        guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct TestTCPServer {
    let port: UInt16
    private let descriptor: Int32

    init(bind host: String) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = ipv4Address(host: host, port: 0)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, listen(descriptor, 16) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard bound == 0 else { throw POSIXError(.EIO) }
            self.descriptor = descriptor
            port = UInt16(bigEndian: address.sin_port)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func close() {
        Darwin.close(descriptor)
    }
}

struct TestUnixServer {
    let path: String
    private let source: DispatchSourceRead
    private let queue: DispatchQueue

    init() throws {
        path = "/private/tmp/ss-" + UUID().uuidString
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                bytes.withUnsafeBytes { target.copyBytes(from: $0) }
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, listen(descriptor, 16) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let queue = DispatchQueue(label: "SkillShelf.TestUnixServer")
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler {
                while true {
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else { break }
                    defer { Darwin.close(client) }
                    guard fcntl(client, F_SETFL, 0) == 0 else { continue }
                    var timeout = timeval(tv_sec: 3, tv_usec: 0)
                    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                    var noSignal: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    guard recv(client, &buffer, buffer.count, 0) > 0 else { continue }
                    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    response.withUnsafeBytes { _ = send(client, $0.baseAddress!, $0.count, 0) }
                }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            self.source = source
            self.queue = queue
        } catch {
            Darwin.close(descriptor)
            unlink(path)
            throw error
        }
    }

    func close() {
        source.cancel()
        queue.sync {}
        unlink(path)
    }
}
