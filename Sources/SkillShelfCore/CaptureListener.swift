import Foundation
import Network
import Synchronization

public enum CaptureFormat: Sendable {
    case anthropic, openAI

    public var errorBody: String {
        switch self {
        case .anthropic:
            #"{"type":"error","error":{"type":"invalid_request_error","message":"SkillShelf capture"}}"#
        case .openAI:
            #"{"error":{"type":"invalid_request_error","code":"skillshelf_capture","message":"SkillShelf capture"}}"#
        }
    }
}

public struct CaptureLimits: Sendable {
    public var headerBytes: Int
    public var bodyBytes: Int
    public var totalBodyBytes: Int
    public var connections: Int
    public var requests: Int
    public static let standard = CaptureLimits()

    public init(
        headerBytes: Int = 65_536, bodyBytes: Int = 33_554_432, totalBodyBytes: Int = 67_108_864,
        connections: Int = 8, requests: Int = 30
    ) {
        self.headerBytes = max(0, headerBytes)
        self.bodyBytes = max(0, bodyBytes)
        self.totalBodyBytes = max(0, totalBodyBytes)
        self.connections = max(0, connections)
        self.requests = max(0, requests)
    }
}

public final class CaptureListener: Sendable {
    private struct Connection {
        let network: NWConnection
        let admitted: Bool
        var parser: HTTPRequestParser?
        var responding = false
        var counted = false
    }

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        var stopping = false
        var stopped = false
        var starts: [CheckedContinuation<UInt16, any Error>] = []
        var stops: [CheckedContinuation<Void, Never>] = []
        var connections: [ObjectIdentifier: Connection] = [:]
        var requestCount = 0
        var bodyBytes = 0
        var notes: [String] = []

        mutating func note(_ value: String) {
            if !notes.contains(value) { notes.append(value) }
        }

        mutating func drop(_ name: String) {
            note("Request over the \(name) limit was dropped")
        }
    }

    public let requests: AsyncStream<CapturedRequest>
    private let continuation: AsyncStream<CapturedRequest>.Continuation
    private let limits: CaptureLimits
    private let response: Data
    private let queue = DispatchQueue(label: "SkillShelf.CaptureListener")
    private let state = Mutex(State())

    public init(format: CaptureFormat, limits: CaptureLimits = .standard) {
        self.limits = limits
        let stream = AsyncStream<CapturedRequest>.makeStream()
        requests = stream.stream
        continuation = stream.continuation
        let body = format.errorBody
        response = Data("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.state.withLock { state in
                    guard !state.stopping && !state.stopped else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let port = state.port {
                        continuation.resume(returning: port)
                        return
                    }
                    state.starts.append(continuation)
                    guard state.listener == nil else { return }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        parameters.acceptLocalOnly = true
                        let listener = try NWListener(using: parameters)
                        state.listener = listener
                        listener.stateUpdateHandler = { [weak self] value in self?.listenerChanged(value) }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                    } catch {
                        self.beginStop(&state, error: error)
                    }
                }
            }
        }
    }

    public func notes() -> [String] {
        state.withLock { $0.notes }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.state.withLock { state in
                    if state.stopped {
                        continuation.resume()
                    } else {
                        state.stops.append(continuation)
                        self.beginStop(&state)
                    }
                }
            }
        }
    }

    private func listenerChanged(_ value: NWListener.State) {
        state.withLock { state in
            switch value {
            case .ready:
                guard !state.stopping, let port = state.listener?.port?.rawValue else { return }
                state.port = port
                let starts = state.starts
                state.starts.removeAll()
                for start in starts { start.resume(returning: port) }
            case .failed(let error):
                beginStop(&state, error: error)
            case .cancelled:
                state.listener?.stateUpdateHandler = nil
                state.listener?.newConnectionHandler = nil
                state.listener = nil
                beginStop(&state)
            default:
                break
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { state in
            let id = ObjectIdentifier(connection)
            let admitted = !state.stopping && state.connections.values.filter(\.admitted).count < limits.connections
            state.connections[id] = Connection(
                network: connection, admitted: admitted,
                parser: admitted ? HTTPRequestParser(limits: limits) : nil
            )
            connection.stateUpdateHandler = { [weak self, weak connection] value in
                guard let connection else { return }
                self?.connectionChanged(connection, value: value)
            }
            connection.start(queue: queue)
            if state.stopping {
                connection.cancel()
            } else if !admitted {
                state.drop("connection")
                respond(id, state: &state)
            }
        }
    }

    private func connectionChanged(_ connection: NWConnection, value: NWConnection.State) {
        let receive = state.withLock { state in
            let id = ObjectIdentifier(connection)
            switch value {
            case .ready:
                return !state.stopping && state.connections[id]?.responding == false
            case .failed:
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
                state.connections.removeValue(forKey: id)
                finishStop(&state)
            default:
                break
            }
            return false
        }
        if receive { receiveNext(connection) }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            self?.received(connection, data: data, complete: complete, error: error)
        }
    }

    private func received(_ connection: NWConnection, data: Data?, complete: Bool, error: NWError?) {
        let receive = state.withLock { state in
            let id = ObjectIdentifier(connection)
            guard !state.stopping, state.connections[id]?.responding == false else { return false }
            if let data, !data.isEmpty {
                if state.connections[id]?.counted == false {
                    state.connections[id]?.counted = true
                    guard state.requestCount < limits.requests else {
                        state.drop("request")
                        respond(id, state: &state)
                        return false
                    }
                    state.requestCount += 1
                }
                let before = state.connections[id]?.parser?.bodyByteCount ?? 0
                let result = state.connections[id]?.parser?.feed(data)
                let count = (state.connections[id]?.parser?.bodyByteCount ?? before) - before
                guard count <= limits.totalBodyBytes - state.bodyBytes else {
                    state.bodyBytes = limits.totalBodyBytes
                    state.drop("total body")
                    respond(id, state: &state)
                    return false
                }
                state.bodyBytes += count
                if let result {
                    switch result {
                    case .request(let method, _, _, _) where method != "POST":
                        break
                    case .request(let method, let path, let body, let encoding):
                        if let encoding { state.note("Compressed body (\(encoding)), not decoded") }
                        continuation.yield(CapturedRequest(
                            method: method, path: path,
                            body: encoding == nil ? String(decoding: body, as: UTF8.self) : body.base64EncodedString(),
                            bodyEncoding: encoding
                        ))
                    case .tooLarge(let name):
                        state.drop(name)
                    case .upgrade:
                        state.note("WebSocket upgrade refused")
                    case .malformed:
                        break
                    }
                    respond(id, state: &state)
                    return false
                }
            }
            if complete || error != nil {
                respond(id, state: &state)
                return false
            }
            return true
        }
        if receive { receiveNext(connection) }
    }

    private func respond(_ id: ObjectIdentifier, state: inout State) {
        guard let connection = state.connections[id]?.network else { return }
        state.connections[id]?.responding = true
        state.connections[id]?.parser = nil
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func beginStop(_ state: inout State, error: any Error = CancellationError()) {
        state.stopping = true
        let starts = state.starts
        state.starts.removeAll()
        for start in starts { start.resume(throwing: error) }
        state.listener?.cancel()
        for connection in state.connections.values { connection.network.cancel() }
        finishStop(&state)
    }

    private func finishStop(_ state: inout State) {
        guard state.stopping, state.listener == nil, state.connections.isEmpty else { return }
        state.stopped = true
        continuation.finish()
        let stops = state.stops
        state.stops.removeAll()
        for stop in stops { stop.resume() }
    }
}
