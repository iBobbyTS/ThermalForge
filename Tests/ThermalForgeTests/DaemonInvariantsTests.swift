//
//  DaemonInvariantsTests.swift
//  ThermalForge
//
//  Phase 3 invariants, tested hardware-free via the extracted decision types:
//  the token-bucket rate limiter (burst / refill / ramp-never-trips / flood) and
//  the thermal-floor decision (engage only for a below-max hold while overheating,
//  restore only past the hysteresis point, thresholds mirrored from FanProfile).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Daemon invariants (Phase 3)")
struct DaemonInvariantsTests {

    // MARK: - Rate limiter

    @Test("burst up to capacity, then rate-limited, then refills at the rate")
    func rateLimiterBucket() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var rl = RateLimiter(capacity: 20, refillPerSecond: 10, now: t0)

        for _ in 0..<20 { let ok = rl.allow(now: t0); #expect(ok) }   // full burst
        let drained = rl.allow(now: t0); #expect(drained == false)   // no time elapsed

        // After 1s, ~10 tokens are back.
        let t1 = t0.addingTimeInterval(1.0)
        var allowed = 0
        for _ in 0..<20 { if rl.allow(now: t1) { allowed += 1 } }
        #expect(allowed == 10)
        let stillDenied = rl.allow(now: t1); #expect(stillDenied == false)
    }

    @Test("a steady ~10/s ramp (the pump's coalesced rate) never trips")
    func rateLimiterRampNeverTrips() {
        var t = Date(timeIntervalSinceReferenceDate: 0)
        var rl = RateLimiter(capacity: 20, refillPerSecond: 10, now: t)
        for _ in 0..<100 {                 // 10s of 10/s, spaced 100ms
            let ok = rl.allow(now: t)
            #expect(ok)
            t = t.addingTimeInterval(0.1)
        }
    }

    @Test("an instantaneous flood is capped at the burst size")
    func rateLimiterFloodThrottled() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        var rl = RateLimiter(capacity: 20, refillPerSecond: 10, now: t)
        var allowed = 0
        for _ in 0..<1000 { if rl.allow(now: t) { allowed += 1 } }
        #expect(allowed == 20)
    }

    // MARK: - Thermal floor decision

    @Test("engages only when overheating is SUSTAINED and a below-max hold is active")
    func thermalFloorEngage() {
        let floor = ThermalFloor()   // 95 / 90 / 2-sample sustain from FanProfile
        // One hot sample — a per-core boost spike — must not engage…
        #expect(floor.evaluate(temp: 95, holdCommand: "set 2000", suspended: false) == .none)
        // …but two consecutive hot samples while a below-max hold pins fans do.
        #expect(floor.evaluate(temp: 96, holdCommand: "setfan 1 1500", suspended: false) == .engage)

        // No hold (auto) → Apple's auto + client monitor own it, even sustained.
        let auto = ThermalFloor()
        #expect(auto.evaluate(temp: 99, holdCommand: nil, suspended: false) == .none)
        #expect(auto.evaluate(temp: 99, holdCommand: nil, suspended: false) == .none)

        // Already max → nothing to override.
        let maxed = ThermalFloor()
        #expect(maxed.evaluate(temp: 99, holdCommand: "max", suspended: false) == .none)
        #expect(maxed.evaluate(temp: 99, holdCommand: "max", suspended: false) == .none)

        // Below threshold → none.
        let cool = ThermalFloor()
        #expect(cool.evaluate(temp: 94.9, holdCommand: "set 2000", suspended: false) == .none)
        #expect(cool.evaluate(temp: 94.9, holdCommand: "set 2000", suspended: false) == .none)
    }

    @Test("a cool sample between hot samples resets the streak (spike over)")
    func thermalFloorStreakResets() {
        let floor = ThermalFloor()
        #expect(floor.evaluate(temp: 95.5, holdCommand: "set 2000", suspended: false) == .none)
        #expect(floor.evaluate(temp: 94.9, holdCommand: "set 2000", suspended: false) == .none)  // spike over
        #expect(floor.evaluate(temp: 96.0, holdCommand: "set 2000", suspended: false) == .none)   // streak restarted
        #expect(floor.evaluate(temp: 96.0, holdCommand: "set 2000", suspended: false) == .engage)
    }

    @Test("restores only after cooling past the hysteresis point")
    func thermalFloorRestoreHysteresis() {
        let floor = ThermalFloor()
        // Still in the 90–95 band → keep max.
        #expect(floor.evaluate(temp: 95, holdCommand: "set 2000", suspended: true) == .none)
        #expect(floor.evaluate(temp: 91, holdCommand: "set 2000", suspended: true) == .none)
        // Cooled below 90 → restore.
        #expect(floor.evaluate(temp: 89.9, holdCommand: "set 2000", suspended: true) == .restore)
        // Restore fires even with the hold cleared (dead app) — daemon then goes to auto.
        #expect(floor.evaluate(temp: 80, holdCommand: nil, suspended: true) == .restore)
    }

    @Test("thresholds mirror FanProfile, not hardcoded numbers")
    func thermalFloorThresholdsMirrorProfile() {
        let floor = ThermalFloor()
        #expect(floor.threshold == FanProfile.safetyTempThreshold)
        #expect(floor.clearBelow == FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees)
        #expect(floor.sustainSamples == max(1, Int(FanProfile.safetySustainSeconds.rounded())))
    }
}
