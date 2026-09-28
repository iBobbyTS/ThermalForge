//
//  DaemonInvariants.swift
//  ThermalForge
//
//  Pure, hardware-free decision logic for the Phase 3 daemon-enforced invariants:
//  a token-bucket rate limiter for SMC-writing verbs, and the thermal-safety-floor
//  state decision. Both take injected inputs (a clock, a temperature) so they unit
//  test without a bound socket or SMC. The DaemonServer performs the actual SMC and
//  state effects; these types only decide.
//

import Foundation

/// Token-bucket rate limiter for the daemon's SMC-writing verbs (`max`/`set`/`setfan`
/// — `auto`/reset is exempt). Burst capacity absorbs a legitimate pump ramp (~10/s,
/// coalescing under backpressure) while a flood drains it to the refill rate and gets
/// `rateLimited`. The clock is injected so the boundary is testable without waiting.
public struct RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var last: Date

    public init(capacity: Double = 20, refillPerSecond: Double = 10, now: Date) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.last = now
    }

    /// Refill for elapsed time, then consume one token if available.
    public mutating func allow(now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(last))
        last = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// The thermal safety floor's decision, given a sampled temperature and the current
/// hold/suspension state. Thresholds are mirrored from `FanProfile` (read, not
/// invented). The DaemonServer maps `.engage`/`.restore` onto SMC + `safetySuspended`.
///
/// A class (not a struct): engagement requires a streak of consecutive hot samples,
/// so `evaluate` carries that decision state. Still effect-free — the daemon
/// performs every SMC write.
public final class ThermalFloor {
    public let threshold: Float
    public let clearBelow: Float
    /// Consecutive hot samples required before engaging. Mirrors
    /// `FanProfile.safetySustainSeconds` (thermalTick samples at 1s, so seconds ==
    /// samples): a single per-core boost spike touching 95°C must not yank the
    /// fans to max and back.
    public let sustainSamples: Int

    private var hotStreak = 0

    public init(threshold: Float = FanProfile.safetyTempThreshold,
                hysteresis: Float = FanProfile.hysteresisDegrees,
                sustainSamples: Int = max(1, Int(FanProfile.safetySustainSeconds.rounded()))) {
        self.threshold = threshold
        self.clearBelow = threshold - hysteresis
        self.sustainSamples = max(1, sustainSamples)
    }

    public enum Action: Equatable {
        case none
        case engage    // overheating while a below-max hold is active → override to max
        case restore   // cooled below the hysteresis point → restore the hold (or auto)
    }

    /// - suspended: is the floor currently overriding fans to max?
    /// - holdCommand: the active hold's command string, or nil for auto / no hold.
    public func evaluate(temp: Float, holdCommand: String?, suspended: Bool) -> Action {
        if suspended {
            // Restore only once cooled past the hysteresis point; otherwise keep max.
            return temp < clearBelow ? .restore : .none
        }
        guard temp >= threshold else {
            hotStreak = 0
            return .none
        }
        // Engage only when overheating is SUSTAINED and a hold pins fans below
        // max. No hold (auto) or an already-max hold needs no override.
        hotStreak += 1
        guard hotStreak >= sustainSamples, let cmd = holdCommand, cmd != "max" else { return .none }
        hotStreak = 0
        return .engage
    }
}
