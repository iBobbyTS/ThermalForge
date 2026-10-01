//
//  SafetyOverrideGateTests.swift
//  ThermalForge
//
//  Client-side safety override decision, tested hardware-free via the extracted
//  gate: hands-off profiles never engage, engagement needs sustained heat (a
//  single-core boost spike is not an emergency), and the [90, 95) release band
//  HOLDS max instead of bang-banging at the threshold. Regression coverage for
//  the Silent-mode fan oscillation observed on M4 Max (2026-09-20 logs).
//

import Testing

@testable import ThermalForgeCore

@Suite("Client safety override gate")
struct SafetyOverrideGateTests {

    @Test("hands-off profiles never engage — Apple owns the safety there")
    func handsOffNeverEngages() {
        var gate = SafetyOverrideGate()
        // Sustained extreme heat, tick after tick: still nothing.
        for _ in 0..<100 {
            #expect(gate.evaluate(handsOff: true, temp: 103) == .normal)
        }
        // A later controlled profile still engages normally (state not poisoned).
        for _ in 0..<19 {
            #expect(gate.evaluate(handsOff: false, temp: 96) == .normal)
        }
        #expect(gate.evaluate(handsOff: false, temp: 96) == .engage)
    }

    @Test("engages only after sustained heat — single spikes pass through")
    func sustainFiltersSpikes() {
        var gate = SafetyOverrideGate()   // 95 / 90 / 20 ticks from FanProfile
        // 19 consecutive hot ticks: not yet.
        for _ in 0..<19 {
            #expect(gate.evaluate(handsOff: false, temp: 95.0) == .normal)
        }
        #expect(gate.evaluate(handsOff: false, temp: 95.0) == .engage)

        // A sub-threshold tick anywhere in the window restarts the streak —
        // the M4 Max log signature was 96°C for ~1s then 74°C.
        var spiky = SafetyOverrideGate()
        for _ in 0..<19 { _ = spiky.evaluate(handsOff: false, temp: 96) }
        #expect(spiky.evaluate(handsOff: false, temp: 94.9) == .normal)   // spike over
        #expect(spiky.evaluate(handsOff: false, temp: 96) == .normal)     // streak restarted
        for _ in 0..<18 {
            #expect(spiky.evaluate(handsOff: false, temp: 96) == .normal)
        }
        #expect(spiky.evaluate(handsOff: false, temp: 96) == .engage)
    }

    @Test("release band [90, 95) HOLDS max — no bang-bang at the threshold")
    func releaseBandHolds() {
        var gate = SafetyOverrideGate()
        for _ in 0..<19 { _ = gate.evaluate(handsOff: false, temp: 96) }
        #expect(gate.evaluate(handsOff: false, temp: 96) == .engage)
        // Temp dips below 95 but not below 90 → hold, hold, hold.
        #expect(gate.evaluate(handsOff: false, temp: 94.5) == .hold)
        #expect(gate.evaluate(handsOff: false, temp: 90.0) == .hold)
        #expect(gate.evaluate(handsOff: false, temp: 94.9) == .hold)
        // Back over the threshold: still maxed — no re-engage churn.
        #expect(gate.evaluate(handsOff: false, temp: 96.5) == .hold)
        // Cooled past 90 → release.
        #expect(gate.evaluate(handsOff: false, temp: 89.9) == .release)
        // After release, cool temps are just normal.
        #expect(gate.evaluate(handsOff: false, temp: 89.0) == .normal)
    }

    @Test("after release, re-engagement needs a fresh sustained window")
    func reengageAfterRelease() {
        var gate = SafetyOverrideGate()
        for _ in 0..<19 { _ = gate.evaluate(handsOff: false, temp: 96) }
        #expect(gate.evaluate(handsOff: false, temp: 96) == .engage)
        #expect(gate.evaluate(handsOff: false, temp: 89) == .release)
        // Immediately hot again: the full window is required, no memory of the
        // previous episode.
        for _ in 0..<19 {
            #expect(gate.evaluate(handsOff: false, temp: 97) == .normal)
        }
        #expect(gate.evaluate(handsOff: false, temp: 97) == .engage)
    }

    @Test("reset() forces a fresh sustained window before re-engagement")
    func resetForcesFreshWindow() {
        var gate = SafetyOverrideGate()
        for _ in 0..<19 { _ = gate.evaluate(handsOff: false, temp: 96) }
        #expect(gate.evaluate(handsOff: false, temp: 96) == .engage)
        // Force re-take: the engaged episode is forgotten.
        gate.reset()
        // Hot immediately, but the full window must be re-earned (not an instant
        // .hold or .engage left over from the reset episode).
        for _ in 0..<19 {
            #expect(gate.evaluate(handsOff: false, temp: 96) == .normal)
        }
        #expect(gate.evaluate(handsOff: false, temp: 96) == .engage)
    }

    @Test("thresholds mirror FanProfile, not hardcoded numbers")
    func thresholdsMirrorProfile() {
        let gate = SafetyOverrideGate()
        #expect(gate.threshold == FanProfile.safetyTempThreshold)
        #expect(gate.clearBelow == FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees)
        #expect(gate.sustainTicks == max(1, Int((FanProfile.safetySustainSeconds / 0.1).rounded())))
    }
}
