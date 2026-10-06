//
//  FanSpeedControllerTests.swift
//  ThermalForge
//
//  Client-side speed trajectory, tested hardware-free via the extracted
//  controller: worst-case span converges inside its direction's deadline
//  (5s up, 10s down), steps scale with the remaining error (small
//  corrections are gentle — the audible-step failure of a linear rate),
//  deceleration is gentler than acceleration, and a moving target is chased
//  without overshoot.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Fan speed controller (PT1)")
struct FanSpeedControllerTests {

    /// This hardware's fallback fan span: 2317–7826 RPM.
    private static let minPct: Float = 2317.0 / 7826.0

    @Test("worst-case span converges within the 5s deadline — up")
    func deadlineUp() {
        var c = FanSpeedController()
        c.resync(Self.minPct)
        var ticks = 0
        while c.current < 1.0 && ticks < 70 {
            _ = c.advance(target: 1.0, dt: 0.1)
            ticks += 1
        }
        #expect(c.current == 1.0)                       // snapped exactly
        #expect(Float(ticks) * 0.1 <= 5.0, "took \(ticks) ticks")
    }

    @Test("worst-case span converges within the 10s deadline — down")
    func deadlineDown() {
        var c = FanSpeedController()
        c.resync(1.0)
        var ticks = 0
        while c.current > Self.minPct && ticks < 120 {
            _ = c.advance(target: Self.minPct, dt: 0.1)
            ticks += 1
        }
        #expect(c.current == Self.minPct)               // snapped exactly
        #expect(Float(ticks) * 0.1 <= 10.0, "took \(ticks) ticks")
    }

    @Test("steps are proportional to the remaining error")
    func proportionalSteps() {
        var far = FanSpeedController()                  // err = 1.0
        var near = FanSpeedController()                 // err = 0.1
        near.resync(0.9)
        let farStep = far.advance(target: 1.0, dt: 0.1) - 0
        let nearStep = near.advance(target: 1.0, dt: 0.1) - 0.9
        // 10× the error → 10× the step: big jumps approach fast, small
        // corrections are inaudible.
        let ratio = farStep / nearStep
        #expect(ratio > 9.5 && ratio < 10.5)
    }

    @Test("deceleration is gentler than acceleration")
    func asymmetricTaus() {
        var up = FanSpeedController()
        var down = FanSpeedController()
        down.resync(1.0)
        var upTicks = 0, downTicks = 0
        while up.current < 1.0 && upTicks < 200 {
            _ = up.advance(target: 1.0, dt: 0.1); upTicks += 1
        }
        while down.current > 0.0 && downTicks < 200 {
            _ = down.advance(target: 0.0, dt: 0.1); downTicks += 1
        }
        #expect(downTicks > upTicks)
        // Full theoretical span down (1.0→0) never happens in the monitor
        // (the min-RPM floor bounds it), so only the relation is locked here.
    }

    @Test("snap lands exactly on the target")
    func snapExactness() {
        var c = FanSpeedController()
        c.resync(0.995)                                 // err 0.005 ≤ snap 0.01
        let landed = c.advance(target: 1.0, dt: 0.1)
        #expect(landed == 1.0)
        #expect(c.current == 1.0)
    }

    @Test("a moving target is chased without overshoot")
    func noOvershootOnMovingTarget() {
        var c = FanSpeedController()
        c.resync(0.5)
        for i in 0..<100 {
            let target: Float = i.isMultiple(of: 2) ? 0.6 : 0.4
            let before = c.current
            _ = c.advance(target: target, dt: 0.1)
            // Moved toward the target, never past it.
            #expect(abs(c.current - target) <= abs(before - target))
            #expect((c.current - before) * (target - before) >= 0)
        }
        #expect(c.current >= 0.4 && c.current <= 0.6)
    }

    @Test("resync teleports, reset forgets")
    func resyncAndReset() {
        var c = FanSpeedController()
        c.resync(0.42)
        #expect(c.current == 0.42)
        _ = c.advance(target: 0.5, dt: 0.1)
        #expect(c.current > 0.42)
        c.reset()
        #expect(c.current == 0)
    }

    @Test("constants mirror FanProfile and satisfy the sizing rule")
    func constantsAndSizing() {
        let c = FanSpeedController()
        #expect(c.tauUp == FanProfile.speedTauUpSeconds)
        #expect(c.tauDown == FanProfile.speedTauDownSeconds)
        #expect(c.snap == FanProfile.speedSnapFraction)
        // tau <= deadline / ln(err0 / snap) with err0 = worst real span;
        // the deadlines are per direction: 5s up, 10s down.
        let err0 = 1.0 - Self.minPct
        let upBound = 5.0 / log(err0 / FanProfile.speedSnapFraction)
        let downBound = 10.0 / log(err0 / FanProfile.speedSnapFraction)
        #expect(FanProfile.speedTauUpSeconds <= upBound)
        #expect(FanProfile.speedTauDownSeconds <= downBound)
    }
}
