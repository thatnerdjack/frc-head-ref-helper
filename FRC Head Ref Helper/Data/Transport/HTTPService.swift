//
//  HTTPService.swift
//  FRC Head Ref Helper
//
//  Every HTTP GET the app makes.
//
//  Bandwidth on a competition venue's Wi-Fi is the constraint this is designed
//  around — it is shared with a few thousand phones and whatever the field is
//  doing — so an unchanged match schedule must not be re-downloaded on every
//  poll.
//
//  That is handled by `URLCache`, not by hand. URLSession already implements
//  HTTP caching: it stores validators, sends `If-None-Match` /
//  `If-Modified-Since`, and turns a 304 back into the cached body before we
//  ever see it. Better still, a response with a `max-age` is served from the
//  cache with NO round trip at all, which conditional GET cannot do. The
//  previous version of this file switched the cache off in order to reimplement
//  the weaker half of it.
//
//  What the app does need — and what the cache cannot tell it — is whether the
//  bytes actually CHANGED, so the projector is not churned with an identical
//  schedule every thirty seconds. That is a digest comparison, below.
//
//  This is a concrete service, not a protocol. Networking is faked with a
//  `URLProtocol` stub (see TransportTests), which exercises this real code path
//  rather than a parallel one written to satisfy a test.
//
//  IMPORTANT: this type does not retry. There is exactly one retry policy in
//  this app and it lives in ReconnectingSocket.swift.
//

import Foundation
import CryptoKit

// MARK: - Errors

nonisolated enum HTTPServiceError: Error, Sendable, Equatable {
    /// A response that was not HTTP at all (only possible for odd schemes).
    case nonHTTPResponse
    /// 4xx/5xx. Carried as data so a caller can distinguish "your API key is
    /// wrong" (401) from "this event has no schedule yet" (404).
    case status(code: Int, body: Data)
    /// Anything the URL loading system reported: no route, TLS failure,
    /// timeout, cancelled.
    case transport(message: String, isCancellation: Bool)
}

// MARK: - Outcome

/// Whether a fetch produced anything new.
///
/// `unchanged` is not the same as a 304 — the cache may have answered without
/// any network at all, or the server may have sent a fresh 200 whose bytes are
/// identical. Both mean "nothing downstream needs to do work", which is the
/// only thing a caller cares about.
nonisolated enum HTTPFetchResult: Sendable, Equatable {
    case changed(Data)
    case unchanged
}

// MARK: - Service

actor HTTPService {

    private let session: URLSession
    /// 32 bytes per URL. Enough to answer "did this change?" without keeping
    /// every schedule we have ever seen resident.
    private var digests: [URL: Data] = [:]

    /// - Parameter configuration: pass a config with `protocolClasses` set to
    ///   stub the network in tests. The default is tuned for a venue.
    init(configuration: URLSessionConfiguration = HTTPService.venueConfiguration()) {
        self.session = URLSession(configuration: configuration)
    }

    /// The production configuration.
    ///
    /// Timeouts are short on purpose: a venue network fails by hanging, not by
    /// refusing, and a head referee would rather be told "can't reach
    /// frc.events" in ten seconds than watch a spinner for sixty.
    ///
    /// `waitsForConnectivity` stays off because connection state is something
    /// this app shows the user, not something it hides behind a stalled
    /// request.
    static func venueConfiguration(
        requestTimeout: TimeInterval = 10,
        resourceTimeout: TimeInterval = 30
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        // On disk, so the schedule survives the app being killed in a pocket
        // and the first poll after a relaunch costs a revalidation at most.
        config.urlCache = URLCache(memoryCapacity: 4 << 20,
                                   diskCapacity: 32 << 20,
                                   directory: nil)
        config.requestCachePolicy = .useProtocolCachePolicy
        return config
    }

    /// Performs a GET and says whether the body differs from the last one seen
    /// for this URL.
    ///
    /// The first call for a URL is always `.changed` — there is nothing to
    /// compare against, and treating an unseen resource as unchanged would
    /// leave the app with no schedule at all.
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPFetchResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw HTTPServiceError.transport(
                message: error.localizedDescription,
                isCancellation: error.code == .cancelled
            )
        } catch is CancellationError {
            throw HTTPServiceError.transport(message: "Cancelled", isCancellation: true)
        } catch {
            // A URLProtocol stub, or anything else, still has to arrive as an
            // HTTPServiceError or callers fall through to a generic handler.
            throw HTTPServiceError.transport(
                message: error.localizedDescription,
                isCancellation: false
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPServiceError.nonHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPServiceError.status(code: http.statusCode, body: data)
        }

        let digest = Data(SHA256.hash(data: data))
        if digests[url] == digest { return .unchanged }
        digests[url] = digest
        return .changed(data)
    }

    /// Forgets what has been seen, so the next fetch of every URL reports
    /// `.changed`. Called when the event changes: the new event's schedule must
    /// reach the projector even if, absurdly, its bytes matched the old one's.
    func reset() {
        digests.removeAll()
    }
}
