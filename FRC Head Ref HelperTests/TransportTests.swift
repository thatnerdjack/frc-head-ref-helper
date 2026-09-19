//
//  TransportTests.swift
//  FRC Head Ref HelperTests
//
//  The transport layer's own behaviour — not the platform's.
//
//  HTTP caching and conditional GET are URLSession's job now, so there is
//  nothing here asserting that an ETag round-trips: that would be testing
//  Foundation. What IS asserted is the part this app added on top — that an
//  identical body is reported as unchanged so the projector is not churned,
//  and that error statuses arrive as typed errors rather than empty bodies.
//
//  The network is faked with a `URLProtocol` stub rather than a protocol
//  abstraction. That is the Apple-sanctioned seam, and it means these tests
//  drive the REAL `HTTPService` code path — the same URLSession, the same
//  request construction — instead of a parallel implementation written to
//  satisfy a mock.
//

import Testing
import Foundation
@testable import FRC_Head_Ref_Helper

// MARK: - URLProtocol stub

/// Answers requests from a script instead of the network.
///
/// Registered via `URLSessionConfiguration.protocolClasses`, so everything
/// above it — caching, header construction, status handling — is the real
/// implementation.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Response: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    /// URLProtocol is instantiated by Foundation, so the script has to be
    /// reachable statically.
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ responses: [Response]) {
        lock.withLock {
            queue = responses
            requests = []
        }
    }

    static var recordedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    private static func next(for request: URLRequest) -> Response {
        lock.withLock {
            requests.append(request)
            // The last scripted response repeats, so a test that polls twice
            // does not have to script the same 200 twice.
            return queue.count > 1 ? queue.removeFirst() : (queue.first ?? Response())
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scripted = Self.next(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: scripted.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: scripted.headers
        )!
        // .notAllowed: the stub is the source of truth for a test, and letting
        // URLCache answer instead would make results depend on test order.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: scripted.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeService() -> HTTPService {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.urlCache = nil
    return HTTPService(configuration: config)
}

private let testURL = URL(string: "https://frc-api.firstinspires.org/v3/2026/schedule/CADA")!

// MARK: - HTTPService

// `.serialized` is not optional here. A URLProtocol subclass is instantiated by
// Foundation, so its script has to live in static storage — which makes it a
// shared resource. Swift Testing runs tests in parallel by default, and without
// this the suite reads another test's scripted response.
@Suite("HTTP service", .serialized)
struct HTTPServiceTests {

    @Test("The first fetch of a URL is always a change")
    func firstFetchIsChanged() async throws {
        // Nothing to compare against — reporting "unchanged" here would leave
        // the app with no schedule at all.
        StubURLProtocol.reset([.init(body: Data("schedule".utf8))])
        let result = try await makeService().get(testURL)
        #expect(result == .changed(Data("schedule".utf8)))
    }

    @Test("An identical body the second time is reported as unchanged")
    func identicalBodyIsUnchanged() async throws {
        // This is the whole point: a poll every thirty seconds must not push an
        // identical schedule through the projector.
        StubURLProtocol.reset([.init(body: Data("same".utf8))])
        let service = makeService()
        _ = try await service.get(testURL)
        #expect(try await service.get(testURL) == .unchanged)
    }

    @Test("A different body is reported as changed")
    func differentBodyIsChanged() async throws {
        StubURLProtocol.reset([
            .init(body: Data("first".utf8)),
            .init(body: Data("second".utf8)),
        ])
        let service = makeService()
        _ = try await service.get(testURL)
        #expect(try await service.get(testURL) == .changed(Data("second".utf8)))
    }

    @Test("Resetting makes the next fetch a change again")
    func resetForgetsDigests() async throws {
        // Called on an event switch: the new event's schedule has to reach the
        // projector even if its bytes somehow matched the old one's.
        StubURLProtocol.reset([.init(body: Data("same".utf8))])
        let service = makeService()
        _ = try await service.get(testURL)
        await service.reset()
        #expect(try await service.get(testURL) == .changed(Data("same".utf8)))
    }

    @Test("Two URLs are tracked independently")
    func urlsAreIndependent() async throws {
        StubURLProtocol.reset([.init(body: Data("body".utf8))])
        let service = makeService()
        _ = try await service.get(testURL)
        let other = URL(string: "https://frc-api.firstinspires.org/v3/2026/teams")!
        // Same bytes, different resource — still new information.
        #expect(try await service.get(other) == .changed(Data("body".utf8)))
    }

    @Test("Caller headers reach the request")
    func headersArePassedThrough() async throws {
        // How the API key gets sent, so it is worth pinning.
        StubURLProtocol.reset([.init(body: Data("x".utf8))])
        _ = try await makeService().get(testURL, headers: ["X-TBA-Auth-Key": "secret"])
        let sent = try #require(StubURLProtocol.recordedRequests.last)
        #expect(sent.value(forHTTPHeaderField: "X-TBA-Auth-Key") == "secret")
    }

    @Test("An error status arrives as a typed error carrying its body")
    func errorStatusIsTyped() async throws {
        // 401 and 404 mean very different things to a referee — "your key is
        // wrong" versus "this event has no schedule yet" — so the code has to
        // survive to the caller.
        StubURLProtocol.reset([.init(statusCode: 404, body: Data("no such event".utf8))])
        await #expect(throws: HTTPServiceError.status(code: 404, body: Data("no such event".utf8))) {
            try await makeService().get(testURL)
        }
    }

    @Test("A failed status does not poison the digest")
    func errorsDoNotRecordADigest() async throws {
        // Otherwise a 500 whose body happened to repeat would make the next
        // successful fetch look unchanged.
        StubURLProtocol.reset([
            .init(statusCode: 500, body: Data("boom".utf8)),
            .init(statusCode: 200, body: Data("boom".utf8)),
        ])
        let service = makeService()
        _ = try? await service.get(testURL)
        #expect(try await service.get(testURL) == .changed(Data("boom".utf8)))
    }
}
