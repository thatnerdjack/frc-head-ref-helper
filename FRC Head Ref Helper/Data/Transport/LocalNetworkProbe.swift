//
//  LocalNetworkProbe.swift
//  FRC Head Ref Helper
//
//  Tells "you denied Local Network permission" apart from "the field server
//  isn't there".
//
//  Why this file exists: on iOS those two produce the *identical* symptom. The
//  socket to 10.0.100.5:8080 just never connects. There is no error, no
//  prompt, nothing in the log. Somebody loses an hour at a competition
//  re-typing the arena IP and power-cycling the field switch when the real fix
//  is one toggle in Settings. An hour is a whole qualification block.
//
//  This is a heuristic, and it says so in its own verdicts. The signals:
//
//   • A TCP RST (`ECONNREFUSED`) is proof permission was GRANTED. A denied app
//     never gets a packet back from a local host at all, so the only way to
//     see a refusal is for our SYN to have actually left the device.
//   • A connection that fails in well under a second, to a private address, on
//     a satisfied path, is the signature of the sandbox dropping it. A real
//     unreachable host burns the full SYN-retry window first.
//   • A full timeout points at the server or the address, not at permission.
//
//  Deliberately NOT implemented with Bonjour. The documented `NWBrowser`
//  trick needs `NSBonjourServices` in Info.plist, and we connect to a typed-in
//  IP rather than discovering anything — declaring Bonjour services we never
//  browse would be a lie in the app's own manifest.
//

import Foundation
import Network

// MARK: - Verdict

nonisolated enum LocalNetworkVerdict: Sendable, Equatable {
    /// The port answered. Nothing to diagnose.
    case reachable
    /// Something answered and said no. Permission is fine; the server is not
    /// listening on that port (Cheesy Arena not started, or wrong port).
    case refused
    /// No usable network path at all — Wi-Fi off, or nothing joined.
    case noNetwork
    /// Failed the way a sandbox denial fails.
    case likelyPermissionDenied
    /// Failed the way an absent host fails.
    case likelyServerUnreachable
    /// The platform has no local-network gate, so this probe cannot say
    /// anything useful beyond reachability.
    case notApplicable

    /// Plain-English guidance, phrased for somebody standing at the scoring
    /// table with a headset on.
    var advice: String {
        switch self {
        case .reachable:
            "Connected."
        case .refused:
            "Reached the server but nothing is listening on that port. Check Cheesy Arena is running, and that the port is right."
        case .noNetwork:
            "This device isn't on any network. Join the field's Wi-Fi."
        case .likelyPermissionDenied:
            "Probably a permissions problem: Settings › FRC Head Ref Helper › Local Network. If that's already on, check the address."
        case .likelyServerUnreachable:
            "No answer from that address. Check the IP, and that this device is on the field's network and not a guest VLAN."
        case .notApplicable:
            "Couldn't reach the server."
        }
    }
}

// MARK: - Probe

/// Opens one throwaway TCP connection and classifies how it failed.
///
/// An `actor` so it does not inherit the target's default `MainActor`
/// isolation — this runs while the UI is showing a spinner.
actor LocalNetworkProbe {
    private let time: any TimeSource
    /// Under this, a failure looks like the sandbox dropping the connection
    /// rather than the network losing it. A SYN to a genuinely absent host on
    /// the same subnet takes seconds to give up; a denial is immediate.
    private let denialThreshold: TimeInterval
    private let timeout: TimeInterval

    init(
        time: any TimeSource = SystemTimeSource(),
        denialThreshold: TimeInterval = 1.0,
        timeout: TimeInterval = 5.0
    ) {
        self.time = time
        self.denialThreshold = denialThreshold
        self.timeout = timeout
    }

    /// - Parameter host: typically the Cheesy Arena address, e.g. 10.0.100.5.
    func probe(host: String, port: UInt16) async -> LocalNetworkVerdict {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .likelyServerUnreachable
        }

        let started = time.monotonicSeconds
        let outcome = await connect(host: host, port: nwPort)
        let elapsed = time.monotonicSeconds - started

        switch outcome {
        case .connected:
            return .reachable
        case .refused:
            return .refused
        case .noPath:
            return .noNetwork
        case .failed:
            return classifyFailure(host: host, elapsed: elapsed)
        }
    }

    /// The heuristic, isolated so its reasoning is readable and so the
    /// platform carve-out is in exactly one place.
    private func classifyFailure(host: String, elapsed: TimeInterval) -> LocalNetworkVerdict {
        #if os(iOS)
        // The Local Network gate only exists for private destinations. A
        // public host failing says nothing about it.
        guard Self.isPrivateIPv4(host) else { return .likelyServerUnreachable }
        return elapsed < denialThreshold ? .likelyPermissionDenied : .likelyServerUnreachable
        #else
        // watchOS, macOS and visionOS builds of this target do not put a
        // user-facing permission gate in front of local addresses, so there is
        // no second explanation to offer.
        _ = (host, elapsed)
        return .notApplicable
        #endif
    }

    // MARK: Connection attempt

    private enum ConnectOutcome: Sendable {
        case connected
        case refused
        case noPath
        case failed
    }

    private func connect(host: String, port: NWEndpoint.Port) async -> ConnectOutcome {
        let parameters = NWParameters.tcp
        // Skip the happy-eyeballs delay and the proxy lookup: this is a
        // diagnostic against a literal address on the local wire.
        parameters.preferNoProxies = true
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )

        let box = OnceBox()
        return await withTaskGroup(of: ConnectOutcome.self) { group in
            group.addTask { [timeout, time] in
                try? await time.sleep(seconds: timeout)
                return .failed
            }
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<ConnectOutcome, Never>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard box.claim() else { return }
                            continuation.resume(returning: .connected)
                        case .waiting(let error):
                            // `.waiting` means "retrying forever". For a
                            // diagnostic that is a failure, and the error code
                            // is the most informative thing we will ever get.
                            guard box.claim() else { return }
                            continuation.resume(returning: Self.outcome(for: error))
                        case .failed(let error):
                            guard box.claim() else { return }
                            continuation.resume(returning: Self.outcome(for: error))
                        case .cancelled:
                            guard box.claim() else { return }
                            continuation.resume(returning: .failed)
                        case .setup, .preparing:
                            break
                        @unknown default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }

            let first = await group.next() ?? .failed
            group.cancelAll()
            connection.cancel()
            return first
        }
    }

    private static func outcome(for error: NWError) -> ConnectOutcome {
        guard case .posix(let code) = error else { return .failed }
        switch code {
        case .ECONNREFUSED:
            // A RST came back, so our packet reached a host. Whatever is
            // wrong, it is not the permission gate.
            return .refused
        case .ENETDOWN, .ENETUNREACH:
            return .noPath
        default:
            return .failed
        }
    }

    /// RFC 1918 plus link-local. Cheesy Arena's default 10.0.100.5 is the
    /// common case; team networks on 192.168.x are the other one.
    nonisolated static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        case (127, _): return true
        default: return false
        }
    }
}
