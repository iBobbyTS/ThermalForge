//
//  TemperatureFilter.swift
//  ThermalForge
//
//  Pure asymmetric low-pass on the peak temperature feeding the fan curve.
//  The curve layer must not see raw sensor noise: P-core peaks oscillate
//  ±5°C at idle-ish load (see AnomalyGate), and that oscillation rides
//  straight through to RPM chatter — the speed controller's taus are sized
//  for human-scale ramps, so they are transparent to second-scale spikes.
//
//  Algorithm mirrors FanSpeedController (first-order exponential, PT1):
//
//      value += (raw - value) * (1 - e^(-dt / tau))
//
//  with tau picked per DIRECTION:
//
//  1. Heating is fast (tau 1.0s): a real workload must raise the curve
//     target without added lag — the controller's own ramp is the acoustic
//     brake, not this filter.
//  2. Cooling is damped hard (tau 6.0s): an idle core's reading falls off a
//     cliff the moment its workload ends (20-30°C in milliseconds), and an
//     unfiltered drop yanks the target down mid-ramp — the same cliff
//     FanOffGate's sustain window guards at the release edge. A 6s tau
//     shrinks a 2s-period swing to ~5% of its amplitude.
//
//  The safety override and anomaly detection deliberately see the RAW
//  temperature: those layers must not be lagged by a filter.
//

import Foundation

public struct TemperatureFilter {
    /// Time-constant when the raw reading is ABOVE the filtered value (heating).
    public let tauUp: Float
    /// Time-constant when the raw reading is BELOW the filtered value (cooling).
    public let tauDown: Float

    /// The filtered peak temperature (°C). Nil until the first sample seeds it.
    public private(set) var value: Float?

    public init(tauUp: Float = FanProfile.tempFilterTauUpSeconds,
                tauDown: Float = FanProfile.tempFilterTauDownSeconds) {
        self.tauUp = tauUp
        self.tauDown = tauDown
    }

    /// Feed one raw sample; returns the filtered value. The first sample
    /// passes through unfiltered — there is no history to smooth against,
    /// and seeding from zero would invent a cold start.
    public mutating func update(raw: Float, dt: Float) -> Float {
        guard let current = value else {
            value = raw
            return raw
        }
        let tau = raw > current ? tauUp : tauDown
        let alpha = -expm1(-dt / max(tau, .ulpOfOne))
        value = current + (raw - current) * alpha
        return value!
    }
}
