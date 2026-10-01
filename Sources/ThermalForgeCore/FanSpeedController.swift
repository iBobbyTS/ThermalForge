//
//  FanSpeedController.swift
//  ThermalForge
//
//  Pure speed-trajectory logic for the client monitor: profiles only produce a
//  TARGET percent each tick; this controller owns the CURRENT percent and moves
//  it toward the target. Hardware-free so it unit-tests without SMC —
//  ThermalMonitor performs the actual fan commands; this type only decides.
//
//  Algorithm: first-order exponential approach (PT1). Each tick consumes a
//  fixed fraction of the REMAINING error:
//
//      current += (target - current) * (1 - e^(-dt / tau))
//
//  Three properties, each earning its place over the linear slew-rate limiter
//  it replaced:
//
//  1. Deadline by construction. tau is sized so the worst-case span (min→max
//     RPM) converges inside the snap band within 3 seconds: tau <= 3 / ln(err0
//     / snap). With err0 ~ 0.70 and snap 0.01 that is tau <= 0.71s.
//  2. Steps proportional to error. A temperature spike that moves the target
//     far commands a fast approach; a 1°C drift nudging the target a few
//     percent moves the fans a few percent — no audible RPM steps on small
//     corrections, which a 3s-sized linear rate (>= 0.23/s) cannot avoid.
//  3. Unconditionally stable on a moving target. The target is recomputed
//     every tick as temperature moves; a first-order chase is a low-pass on
//     the target signal — no overshoot, no tuning conditions.
//
//  Asymmetric taus keep the old governors' acoustic intent (faster up for
//  thermal safety, gentler down), both still inside the 3s deadline.
//

import Foundation

public struct FanSpeedController {
    /// Approach time-constant when the target is ABOVE current (seconds).
    public let tauUp: Float
    /// Approach time-constant when the target is BELOW current (seconds).
    public let tauDown: Float
    /// Land exactly on the target once within this fraction of max RPM.
    public let snap: Float

    /// The controller's present speed as a fraction of max RPM (0.0–1.0).
    public private(set) var current: Float

    public init(tauUp: Float = FanProfile.speedTauUpSeconds,
                tauDown: Float = FanProfile.speedTauDownSeconds,
                snap: Float = FanProfile.speedSnapFraction,
                current: Float = 0) {
        self.tauUp = tauUp
        self.tauDown = tauDown
        self.snap = snap
        self.current = current
    }

    /// One tick toward the target. Returns the new current (also stored).
    public mutating func advance(target: Float, dt: Float) -> Float {
        let tau = target > current ? tauUp : tauDown
        let alpha = -expm1(-dt / max(tau, .ulpOfOne))
        current += (target - current) * alpha
        if abs(target - current) <= snap {
            current = target
        }
        return current
    }

    /// Teleport the state — the two legitimate jumps, never a glide:
    /// bumpless takeover from Apple auto (seed from observed RPM) and
    /// instantEngage / safety-release bookkeeping.
    public mutating func resync(_ value: Float) {
        current = value
    }

    /// Forget the trajectory — call exactly where a resetAuto hands the fans
    /// back to the system, so the next takeover re-seeds from reality.
    public mutating func reset() {
        current = 0
    }
}
