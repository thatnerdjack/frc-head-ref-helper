//
//  HTTPTransporting.swift
//  FRC Head Ref Helper
//
//  One HTTP GET, abstracted so it can be faked.
//
//  Conditional GET is the whole reason this file is more than four lines.
//  Both The Blue Alliance and frc.events return `ETag` / `Last-Modified` and
//  honour `If-None-Match` / `If-Modified-Since`, answering an unchanged
//  resource with a 304 and an empty body. On the shared, saturated Wi-Fi of a
//  competition venue that is the difference between a 200-byte round trip and
//  re-downloading a full match schedule every poll. It is also politeness:
//  TBA rate-limits, and a 304 is cheap for them too.
//
//  IMPORTANT: this type does not retry. See ReconnectingSocket.swift — there
//  is exactly one retry policy in this app and it does not live here.
//

import Foundation

// MARK: - Cache validators

/// The opaque tokens a server hands back so we can ask "has this changed?"
///
/// Both fields are stored and replayed *verbatim*. They are byte strings to
/// the server, not values: an ETag keeps its quotes and any `W/` weak prefix,
/// and a `Last-Modified` date is never reparsed and reformatted. Re-rendering
/// an HTTP date through `DateFormatter` is the classic way to turn a working
/// 304 into a permanent 200 — a one-character difference in the day-of-week
/// abbreviation and the server simply stops matching it.
nonisolated struct CacheValidator: Sendable, Hashable, Codable {
    var eTag: String?
    var lastModified: String?

    init(eTag: String? = nil, lastModified: String? = nil) {
        self.eTag = eTag.flatMap(Self.normalized)
        self.lastModified = lastModified.flatMap(Self.normalized)
    }

    /// Nothing to revalidate against — the caller must do an unconditional GET.
    var isEmpty: Bool { eTag == nil && lastModified == nil }

    /// Blank and whitespace-only header values are worse than absent: sending
    /// `If-None-Match: ` makes some servers 400 the request.
    private static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Response

/// An HTTP response as a plain value.
///
/// Deliberately *not* `HTTPURLResponse`. A test double should not have to
/// conjure a URL and unwrap an optional initialiser just to say "the server
/// said 200"; and keeping the URL loading system's classes out of the protocol
/// is what lets the replay-based test transport exist at all.
nonisolated struct HTTPResponseValue: Sendable {
    var statusCode: Int
    /// Header names lower-cased on the way in, because HTTP header names are
    /// case-insensitive and every server spells them differently.
    var headers: [String: String]
    var body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }

    func headerValue(_ name: String) -> String? { headers[name.lowercased()] }

    /// The validators to store alongside the body for the next request.
    var validator: CacheValidator {
        CacheValidator(eTag: headerValue("ETag"), lastModified: headerValue("Last-Modified"))
    }
}

/// What a conditional GET actually produced.
///
/// 304 is modelled as its own case rather than a status code the caller might
/// forget to check. A 304 body is empty, so a caller that treated it like a
/// 200 would decode an empty schedule and blank the screen mid-event.
nonisolated enum HTTPFetchOutcome: Sendable {
    /// Fresh content.
    case fetched(HTTPResponseValue)
    /// Unchanged. Keep the cached copy; refresh the stored validator with this
    /// one, since a server may rotate an ETag on a 304.
    case notModified(CacheValidator)
}

// MARK: - Errors

nonisolated enum HTTPTransportError: Error, Sendable, Equatable {
    /// A response that was not HTTP at all (only possible for odd schemes).
    case nonHTTPResponse
    /// 4xx/5xx. Carried as data so a caller can distinguish "your API key is
    /// wrong" (401) from "this event has no schedule yet" (404).
    case status(code: Int, body: Data)
    /// Anything the URL loading system reported: no route, TLS failure,
    /// timeout, cancelled.
    case transport(message: String, isCancellation: Bool)
}

// MARK: - Protocol

/// A single HTTP GET. That is the entire surface area, and it should stay that
/// way: the smaller this is, the less a test double has to lie about.
nonisolated protocol HTTPTransporting: Sendable {
    /// Performs a GET, adding conditional headers when `validator` is non-nil.
    ///
    /// - Parameter headers: caller-supplied headers (an API key, say). These
    ///   are applied first, so the conditional headers derived from
    ///   `validator` always win over a hand-written `If-None-Match`.
    func get(
        _ url: URL,
        headers: [String: String],
        validator: CacheValidator?
    ) async throws -> HTTPFetchOutcome
}

nonisolated extension HTTPTransporting {
    func get(_ url: URL) async throws -> HTTPFetchOutcome {
        try await get(url, headers: [:], validator: nil)
    }
}

// MARK: - Conditional GET header rules

/// The pure part of conditional GET, pulled out so it can be tested without a
/// server, a socket, or a clock.
nonisolated enum ConditionalGET {
    static let ifNoneMatch = "If-None-Match"
    static let ifModifiedSince = "If-Modified-Since"

    /// Builds the outgoing header set.
    ///
    /// Both validators are sent when we have both. RFC 9110 says a server that
    /// understands `If-None-Match` must ignore `If-Modified-Since`, so the
    /// pair is not contradictory — it just means an origin that only
    /// implements one of them still gets a usable condition.
    static func requestHeaders(
        base: [String: String] = [:],
        validator: CacheValidator?
    ) -> [String: String] {
        guard let validator, !validator.isEmpty else { return base }

        // Drop any spelling of the two conditional headers the caller supplied
        // before inserting ours. Simply overwriting by exact key would leave
        // `if-none-match` and `If-None-Match` as two separate dictionary
        // entries; `URLRequest.setValue(_:forHTTPHeaderField:)` is
        // case-insensitive and last-write-wins, and a dictionary has no
        // defined iteration order — so a stale validator would beat the fresh
        // one at random, produce a spurious 304, and quietly freeze the match
        // schedule mid-event.
        let ours = [ifNoneMatch.lowercased(), ifModifiedSince.lowercased()]
        var headers = base.filter { !ours.contains($0.key.lowercased()) }

        if let eTag = validator.eTag { headers[ifNoneMatch] = eTag }
        if let lastModified = validator.lastModified { headers[ifModifiedSince] = lastModified }
        return headers
    }

    /// Merges the validator a 304 carried over the one we already had.
    ///
    /// A 304 is allowed to omit the validators entirely, which means "the ones
    /// you sent are still current". Dropping our stored copy in that case
    /// would silently downgrade every future poll to an unconditional GET.
    static func refreshed(_ stored: CacheValidator?, with response: HTTPResponseValue) -> CacheValidator {
        let fresh = response.validator
        return CacheValidator(
            eTag: fresh.eTag ?? stored?.eTag,
            lastModified: fresh.lastModified ?? stored?.lastModified
        )
    }
}

// MARK: - URLSession implementation

/// The real thing.
///
/// An `actor` because the app target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: without this annotation a
/// plain type would be main-actor isolated and every fetch would hop back to
/// the UI thread to hand over its bytes.
actor URLSessionHTTPTransport: HTTPTransporting {
    private let session: URLSession

    /// - Parameter requestTimeout: short on purpose. A venue network fails by
    ///   hanging, not by refusing, and a head referee would rather see "can't
    ///   reach frc.events" in ten seconds than watch a spinner for sixty.
    init(requestTimeout: TimeInterval = 10, resourceTimeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        // We do our own revalidation. URLSession's cache would otherwise
        // revalidate behind our back and hand us a synthesised 200 from disk,
        // so we would never see a 304 and our stored validators would never
        // update.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Fail fast rather than parking the request until connectivity
        // returns: connection state is something this app shows the user, not
        // something it hides behind a stalled request.
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // No default arguments here: the protocol extension above already supplies
    // the convenience overload, and having both would make `get(url)`
    // ambiguous at the concrete type.
    func get(
        _ url: URL,
        headers: [String: String],
        validator: CacheValidator?
    ) async throws -> HTTPFetchOutcome {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in ConditionalGET.requestHeaders(base: headers, validator: validator) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw HTTPTransportError.transport(
                message: error.localizedDescription,
                isCancellation: error.code == .cancelled
            )
        } catch is CancellationError {
            throw HTTPTransportError.transport(message: "Cancelled", isCancellation: true)
        } catch {
            // Everything else — a POSIXError, or whatever a URLProtocol stub
            // in a test decides to throw — still has to arrive as an
            // `HTTPTransportError`, or callers written against the documented
            // error surface silently fall through to a generic handler.
            throw HTTPTransportError.transport(
                message: error.localizedDescription,
                isCancellation: false
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.nonHTTPResponse
        }

        let value = HTTPResponseValue(
            statusCode: http.statusCode,
            headers: Self.headerFields(from: http),
            body: data
        )

        switch value.statusCode {
        case 304:
            return .notModified(ConditionalGET.refreshed(validator, with: value))
        case 200...299:
            return .fetched(value)
        default:
            throw HTTPTransportError.status(code: value.statusCode, body: data)
        }
    }

    /// `allHeaderFields` is `[AnyHashable: Any]`; flatten it to strings so
    /// nothing non-`Sendable` escapes this actor.
    private static func headerFields(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            result[name.lowercased()] = String(describing: value)
        }
        return result
    }
}
