import Darwin
import Foundation
import Testing
@testable import SkillShelfCore

struct CaptureListenerTests {
    @Test(arguments: [CaptureFormat.anthropic, .openAI])
    func recordsBodyAndAnswersAdapterError(_ format: CaptureFormat) async throws {
        try await withListener(format) { listener, port in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages?mode=test")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"a":1}"#.utf8)
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 400)
            #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(http.value(forHTTPHeaderField: "Connection") == "close")
            let expected = format == .anthropic
                ? #"{"type":"error","error":{"type":"invalid_request_error","message":"SkillShelf capture"}}"#
                : #"{"error":{"type":"invalid_request_error","code":"skillshelf_capture","message":"SkillShelf capture"}}"#
            #expect(String(decoding: data, as: UTF8.self) == expected)
            await listener.stop()
            let captured = await collectedRequests(listener)
            #expect(captured == [CapturedRequest(method: "POST", path: "/v1/messages?mode=test", body: #"{"a":1}"#, bodyEncoding: nil)])
            #expect(!String(describing: captured).contains("secret"))
            #expect(!listener.notes().joined().contains("secret"))
        }
    }

    @Test func chunkedBodySplitAcrossFeedsIsReassembled() throws {
        let raw = Array("POST /r HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3;name=value\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: secret\r\n\r\n".utf8)
        for split in 0...raw.count {
            var parser = HTTPRequestParser(limits: .standard)
            let first = parser.feed(Data(raw[..<split]))
            let result = parser.feed(Data(raw[split...])) ?? first
            guard case .request(let method, let path, let body, let encoding) = result else {
                Issue.record("no request at split \(split)")
                continue
            }
            #expect(method == "POST")
            #expect(path == "/r")
            #expect(String(decoding: body, as: UTF8.self) == "abcde")
            #expect(encoding == nil)
        }
        var parser = HTTPRequestParser(limits: .standard)
        var result: HTTPRequestParser.Result?
        for byte in raw { result = parser.feed(Data([byte])) ?? result }
        guard case .request(_, _, let body, _) = result else { Issue.record("no bytewise request"); return }
        #expect(body == Data("abcde".utf8))
    }

    @Test func contentLengthHandlesSplitHeadersAndBinaryBody() {
        var parser = HTTPRequestParser(limits: CaptureLimits(bodyBytes: 4))
        let header = Data("POST /r HTTP/1.1\r\ncOnTeNt-LeNgTh: 4\r\nContent-Encoding: GZip\r\n\r\n".utf8)
        for byte in header { #expect(parser.feed(Data([byte])) == nil) }
        #expect(parser.feed(Data([0, 255])) == nil)
        guard case .request(_, _, let body, let encoding) = parser.feed(Data([13, 10])) else {
            Issue.record("no request")
            return
        }
        #expect(body == Data([0, 255, 13, 10]))
        #expect(encoding == "gzip")
    }

    @Test func oversizedHeaderAndBodyAreRejected() {
        var body = HTTPRequestParser(limits: CaptureLimits(bodyBytes: 4))
        guard case .tooLarge("body") = body.feed(Data("POST /r HTTP/1.1\r\nContent-Length: 10\r\n\r\n".utf8)) else { Issue.record("body"); return }
        var header = HTTPRequestParser(limits: CaptureLimits(headerBytes: 16))
        guard case .tooLarge("header") = header.feed(Data("POST /r HTTP/1.1\r\nX-Long: aaaaaaaaaaaa\r\n".utf8)) else { Issue.record("header"); return }
    }

    @Test func headerLimitDoesNotCountBodyAndIncludesTerminator() {
        let header = "POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\n"
        var exact = HTTPRequestParser(limits: CaptureLimits(headerBytes: header.utf8.count, bodyBytes: 4))
        guard case .request(_, _, let body, _) = exact.feed(Data((header + "abcd").utf8)) else { Issue.record("exact limits rejected"); return }
        #expect(body == Data("abcd".utf8))
        var over = HTTPRequestParser(limits: CaptureLimits(headerBytes: header.utf8.count - 1))
        guard case .tooLarge("header") = over.feed(Data(header.utf8)) else { Issue.record("header terminator uncounted"); return }
    }

    @Test func chunkSizesAndTrailersAreBounded() {
        for chunks in ["5\r\n", "3\r\nabc\r\n2\r\n"] {
            var parser = HTTPRequestParser(limits: CaptureLimits(bodyBytes: 4))
            guard case .tooLarge("body") = parser.feed(Data(("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + chunks).utf8)) else { Issue.record("chunk body limit"); continue }
        }
        for suffix in [String(repeating: "1", count: 65), "0\r\nX: " + String(repeating: "a", count: 65)] {
            var parser = HTTPRequestParser(limits: CaptureLimits(headerBytes: 64))
            guard case .tooLarge("header") = parser.feed(Data(("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + suffix).utf8)) else { Issue.record("chunk metadata limit"); continue }
        }
    }

    @Test func manySmallChunksDoNotConsumeHeaderBudget() {
        var parser = HTTPRequestParser(limits: CaptureLimits(headerBytes: 64))
        let raw = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(repeating: "1\r\nx\r\n", count: 100) + "0\r\n\r\n"
        guard case .request(_, _, let body, _) = parser.feed(Data(raw.utf8)) else {
            Issue.record("chunk framing consumed header budget")
            return
        }
        #expect(body == Data(repeating: 120, count: 100))
    }

    @Test(arguments: [
        "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nxyz\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx!!",
        "POST / HTTP/1.1\r\n Bad: folded\r\n\r\n",
        "POST / HTTP/1.1\r\nMissingColon\r\n\r\n",
        "POST / HTTP/2.0\r\n\r\n",
    ])
    func malformedFramingIsRejected(_ raw: String) {
        var parser = HTTPRequestParser(limits: .standard)
        guard case .malformed = parser.feed(Data(raw.utf8)) else { Issue.record("accepted malformed framing"); return }
    }

    @Test func gzipBodyIsStoredEncodedWithNote() async throws {
        try await withListener(.openAI) { listener, port in
            let status = try await rawPost(port: port, headers: ["Content-Encoding: gzip"], body: Data([0x1f, 0x8b, 0x08]))
            #expect(status == 400)
            await listener.stop()
            let requests = await collectedRequests(listener)
            #expect(requests.first?.body == "H4sI")
            #expect(requests.first?.bodyEncoding == "gzip")
            #expect(listener.notes() == ["Compressed body (gzip), not decoded"])
        }
    }

    @Test func chunkedRequestsAreRecordedWithoutTrailerHeaders() async throws {
        try await withListener(.openAI) { listener, port in
            let response = try await rawExchange(port: port, data: Data("POST /r HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Encoding: identity\r\n\r\n3\r\nabc\r\n0\r\nAuthorization: secret\r\n\r\n".utf8))
            #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            await listener.stop()
            let requests = await collectedRequests(listener)
            #expect(requests == [CapturedRequest(method: "POST", path: "/r", body: "abc", bodyEncoding: nil)])
            #expect(listener.notes().isEmpty)
        }
    }

    @Test func upgradeIsRefused() async throws {
        try await withListener(.openAI) { listener, port in
            let status = try await rawPost(port: port, headers: ["Connection: Upgrade", "Upgrade: websocket"], body: Data())
            #expect(status == 400)
            await listener.stop()
            #expect(await collectedRequests(listener).isEmpty)
            #expect(listener.notes() == ["WebSocket upgrade refused"])
        }
    }

    @Test func portProbesAreAnsweredButNeverRecorded() async throws {
        try await withListener(.openAI) { listener, port in
            let probe = try await rawExchange(port: port, data: Data("GET / HTTP/1.1\r\nHost: localhost\r\nUser-Agent: node\r\n\r\n".utf8))
            #expect(probe.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            let post = try await rawExchange(port: port, data: Data("POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8))
            #expect(post.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            await listener.stop()
            #expect(await collectedRequests(listener) == [CapturedRequest(method: "POST", path: "/v1/responses", body: "{}", bodyEncoding: nil)])
            #expect(listener.notes().isEmpty)
        }
    }

    @Test func requestAndTotalLimitsDropExtras() async throws {
        try await withListener(.openAI, limits: CaptureLimits(totalBodyBytes: 10, requests: 2)) { listener, port in
            for _ in 0..<4 {
                let status = try await rawPost(port: port, headers: [], body: Data("123456".utf8))
                #expect(status == 400)
            }
            await listener.stop()
            #expect(await collectedRequests(listener).count == 1)
            #expect(listener.notes().sorted() == ["Request over the request limit was dropped", "Request over the total body limit was dropped"])
        }
    }

    @Test func oversizedRequestsAnswerAndNeverRecord() async throws {
        try await withListener(.anthropic, limits: CaptureLimits(headerBytes: 64, bodyBytes: 4)) { listener, port in
            for raw in [
                "POST /r HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: 70) + "\r\n\r\n",
                "POST /r HTTP/1.1\r\nContent-Length: 5\r\n\r\n",
                "POST /r HTTP/1.1\r\nContent-Length: 6\r\n\r\n",
            ] {
                let response = try await rawExchange(port: port, data: Data(raw.utf8))
                #expect(response.hasSuffix("\r\n\r\n" + CaptureFormat.anthropic.errorBody))
            }
            await listener.stop()
            #expect(await collectedRequests(listener).isEmpty)
            #expect(listener.notes().sorted() == ["Request over the body limit was dropped", "Request over the header limit was dropped"])
        }
    }

    @Test func totalLimitRejectsIncompleteBodiesAndExhaustsBudget() async throws {
        try await withListener(.openAI, limits: CaptureLimits(totalBodyBytes: 4)) { listener, port in
            let response = try await rawExchange(port: port, data: Data("POST /r HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8))
            #expect(response.hasSuffix("\r\n\r\n" + CaptureFormat.openAI.errorBody))
            let status = try await rawPost(port: port, headers: [], body: Data("x".utf8))
            #expect(status == 400)
            await listener.stop()
            #expect(await collectedRequests(listener).isEmpty)
            #expect(listener.notes() == ["Request over the total body limit was dropped"])
        }
    }

    @Test func connectionLimitClosesExtraConnections() async throws {
        try await withListener(.openAI, limits: CaptureLimits(connections: 1)) { listener, port in
            let first = try openIdleConnection(port: port)
            defer { close(first) }
            #expect(try await rawPost(port: port, headers: [], body: Data("x".utf8)) == 400)
            #expect(listener.notes() == ["Request over the connection limit was dropped"])
            await listener.stop()
            #expect(await collectedRequests(listener).isEmpty)
        }
    }

    @Test func listenerIsLoopbackOnly() async throws {
        try await withListener(.openAI) { _, port in
            let addresses = LocalAddresses.nonLoopbackIPv4()
            try #require(!addresses.isEmpty, "needs a non-loopback interface")
            #expect(addresses.allSatisfy { !TCPProbe.connects(host: $0, port: port) })
            #expect(try await rawPost(port: port, headers: [], body: Data()) == 400)
        }
    }

    @Test func stopFinishesStreamClosesConnectionsAndPort() async throws {
        try await withListener(.openAI) { listener, port in
            let first = try openIdleConnection(port: port)
            defer { close(first) }
            async let stopOne: Void = listener.stop()
            async let stopTwo: Void = listener.stop()
            _ = await (stopOne, stopTwo)
            #expect(!TCPProbe.connects(host: "127.0.0.1", port: port))
            #expect(await collectedRequests(listener).isEmpty)
            var byte: UInt8 = 0
            #expect(recv(first, &byte, 1, 0) <= 0)
        }
    }

    @Test func stopBeforeStartAndConcurrentStartsSettle() async throws {
        let unused = CaptureListener(format: .openAI)
        await unused.stop()
        await #expect(throws: (any Error).self) { try await unused.start() }
        let listener = CaptureListener(format: .openAI)
        do {
            async let first = listener.start()
            async let second = listener.start()
            let ports = try await (first, second)
            #expect(ports.0 == ports.1)
            await listener.stop()
        } catch {
            await listener.stop()
            throw error
        }
    }
}
