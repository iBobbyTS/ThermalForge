//
//  HeartbeatTally.swift
//  ThermalForge
//
//  Consecutive-miss tally for the app's daemon heartbeat, splitting misses
//  into "helper gone" (hard) and "helper alive but starved" (soft). The split
//  decides whether the supervision loop may treat the helper as dead.
//

import Foundation

/// Classification of one missed daemon heartbeat.
///
/// The 2026-10-05 load test showed why the split is needed: under sustained
/// full CPU load the helper stays alive but its replies exceed the client's
/// socket budget, so every miss arrives as a timeout. Treating those like a
/// dead helper (two misses → verified re-register cycle → `.restart`)
/// destroyed a healthy process and manufactured the very control gap the
/// check meant to close — a Max hold pinned at 5777 RPM dropped to 1354 RPM
/// for ~35s while the restart cycled.
public enum HeartbeatMissKind: Equatable, Sendable {
    /// The helper process is gone or the connection broke (EOF, connect
    /// refused, I/O error). Fast re-register / restart is the right response.
    case hard
    /// The helper is alive but starved — a bounded-wait timeout expired.
    /// Retry patiently; restarting a live helper mid-load only widens the
    /// outage window.
    case soft

    /// Map a thrown heartbeat error to its miss kind. Timeout frame errors are
    /// soft; everything else — `closed`, `readFailed`/`writeFailed`,
    /// `DaemonError.notRunning`, unrecognized errors — is hard. The
    /// conservative default keeps the old fast-recovery behavior for anything
    /// the classifier doesn't recognize.
    public static func classify(_ error: Error) -> HeartbeatMissKind {
        switch error as? DaemonProtocol.FrameError {
        case .readTimeout, .writeTimeout: return .soft
        default: return .hard
        }
    }
}

/// Independent consecutive-miss counters for the two miss kinds. Any success
/// resets both (liveness is liveness). The tally trips when EITHER counter
/// reaches its threshold:
///
/// - hard: 2 beats (≈10s) — the helper is provably gone; the old behavior,
///   unchanged.
/// - soft: 4 beats (≈20s+) — the helper answers too slowly to be supervised.
///   That really does warrant a restart, but only after the longer fuse: the
///   2026-10-05 run showed single soft misses recover on the very next beat
///   (13 of them, zero escalation). The threshold stays inside the daemon's
///   30s supervised-hold silence limit, so a genuinely wedged helper is
///   restarted by this path before its watchdog would drop the hold.
///
/// The counters are independent on purpose: one hard miss (a connection
/// refusal during a helper restart window) among load-induced timeouts must
/// not borrow the soft count's longer fuse, and vice versa.
public struct HeartbeatTally: Sendable {
    public let hardThreshold: Int
    public let softThreshold: Int
    public private(set) var hardMisses: Int = 0
    public private(set) var softMisses: Int = 0

    public init(hardThreshold: Int = 2, softThreshold: Int = 4) {
        self.hardThreshold = max(1, hardThreshold)
        self.softThreshold = max(1, softThreshold)
    }

    /// Record a miss of `kind` and return whether a threshold was reached —
    /// the caller's cue to declare the helper unreachable and enter recovery.
    @discardableResult
    public mutating func record(_ kind: HeartbeatMissKind) -> Bool {
        switch kind {
        case .hard:
            hardMisses += 1
            return hardMisses >= hardThreshold
        case .soft:
            softMisses += 1
            return softMisses >= softThreshold
        }
    }

    /// A successful heartbeat. Proves liveness; clears both counts.
    public mutating func reset() {
        hardMisses = 0
        softMisses = 0
    }
}
