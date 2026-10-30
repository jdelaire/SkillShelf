import Foundation

struct HTTPRequestParser: Sendable {
    enum Result: Sendable {
        case request(method: String, path: String, body: Data, encoding: String?)
        case tooLarge(String)
        case upgrade
        case malformed
    }

    private enum Phase {
        case headers, fixed(Int), chunkSize, chunkData(Int), chunkTerminator(Int), trailers, finished
    }

    private let limits: CaptureLimits
    private var phase = Phase.headers
    private var metadata: [UInt8] = []
    private var metadataBytes = 0
    private var body = Data()
    private var method = ""
    private var path = ""
    private var encoding: String?
    private(set) var bodyByteCount = 0

    init(limits: CaptureLimits) {
        self.limits = limits
    }

    mutating func feed(_ data: Data) -> Result? {
        var index = data.startIndex
        while index < data.endIndex {
            switch phase {
            case .finished:
                return nil
            case .headers, .chunkSize, .trailers:
                if case .chunkSize = phase {
                    guard metadata.count < limits.headerBytes else { return finish(.tooLarge("header")) }
                } else {
                    guard metadataBytes < limits.headerBytes else { return finish(.tooLarge("header")) }
                    metadataBytes += 1
                }
                let byte = data[index]
                index += 1
                metadata.append(byte)
                switch phase {
                case .headers:
                    if metadata.suffix(4).elementsEqual([13, 10, 13, 10]) {
                        let result = parseHeaders()
                        metadata.removeAll(keepingCapacity: false)
                        if let result { return finish(result) }
                    }
                case .chunkSize, .trailers:
                    if metadata.suffix(2).elementsEqual([13, 10]) {
                        let line = Array(metadata.dropLast(2))
                        metadata.removeAll(keepingCapacity: false)
                        if case .trailers = phase {
                            if line.isEmpty { return complete() }
                            guard Self.headerField(line) != nil else { return finish(.malformed) }
                        } else {
                            let size = line.prefix { $0 != 59 }
                            guard !size.isEmpty, size.allSatisfy(Self.isHex) else { return finish(.malformed) }
                            guard let count = Int(String(decoding: size, as: UTF8.self), radix: 16),
                                  count <= limits.bodyBytes - bodyByteCount else { return finish(.tooLarge("body")) }
                            phase = count == 0 ? .trailers : .chunkData(count)
                        }
                    }
                default:
                    break
                }
            case .fixed(let remaining), .chunkData(let remaining):
                let count = min(remaining, data.endIndex - index)
                body.append(data[index..<(index + count)])
                bodyByteCount += count
                index += count
                if case .fixed = phase {
                    if count == remaining { return complete() }
                    phase = .fixed(remaining - count)
                } else {
                    phase = count == remaining ? .chunkTerminator(0) : .chunkData(remaining - count)
                }
            case .chunkTerminator(let offset):
                guard data[index] == (offset == 0 ? 13 : 10) else { return finish(.malformed) }
                index += 1
                phase = offset == 0 ? .chunkTerminator(1) : .chunkSize
            }
        }
        if case .fixed(0) = phase { return complete() }
        return nil
    }

    private mutating func parseHeaders() -> Result? {
        let lines = String(decoding: metadata.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1",
              !request[0].isEmpty, request[0].utf8.allSatisfy(Self.isToken),
              !request[1].isEmpty, request[1].utf8.allSatisfy({ (33...126).contains($0) }) else { return .malformed }
        method = String(request[0])
        path = String(request[1])
        var length: String?
        var transfer: String?
        var upgrade = false
        for line in lines.dropFirst() {
            guard let (name, value) = Self.headerField(Array(line.utf8)) else { return .malformed }
            switch name {
            case "content-length":
                guard length == nil else { return .malformed }
                length = value
            case "transfer-encoding":
                guard transfer == nil else { return .malformed }
                transfer = value.lowercased()
            case "content-encoding":
                guard encoding == nil, !value.isEmpty else { return .malformed }
                encoding = value.lowercased()
            case "upgrade":
                upgrade = upgrade || value.lowercased() == "websocket"
            case "connection":
                upgrade = upgrade || value.lowercased().split(separator: ",").contains {
                    $0.trimmingCharacters(in: .whitespaces) == "upgrade"
                }
            default:
                break
            }
        }
        if upgrade { return .upgrade }
        if encoding == "identity" { encoding = nil }
        if let transfer {
            guard transfer == "chunked", length == nil else { return .malformed }
            phase = .chunkSize
        } else if let length {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }) else { return .malformed }
            guard let count = Int(length), count <= limits.bodyBytes else { return .tooLarge("body") }
            phase = .fixed(count)
        } else {
            phase = .fixed(0)
        }
        return nil
    }

    private static func headerField(_ bytes: [UInt8]) -> (String, String)? {
        guard let colon = bytes.firstIndex(of: 58), colon > 0,
              bytes[..<colon].allSatisfy(isToken),
              bytes[(colon + 1)...].allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { return nil }
        let name = String(decoding: bytes[..<colon], as: UTF8.self).lowercased()
        let value = String(decoding: bytes[(colon + 1)...], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return (name, value)
    }

    private static func isToken(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private mutating func complete() -> Result {
        finish(.request(method: method, path: path, body: body, encoding: encoding))
    }

    private mutating func finish(_ result: Result) -> Result {
        phase = .finished
        metadata.removeAll(keepingCapacity: false)
        body = Data()
        return result
    }
}
