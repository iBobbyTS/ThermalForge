//
//  SafetyOverrideGate.swift
//  ThermalForge
//
//  Pure decision logic for the client monitor's thermal safety override.
//  Hardware-free so it unit-tests without SMC — ThermalMonitor performs the
//  actual fan commands; this type only decides.
//
//  Three properties, all fixing the Silent-mode bang-bang observed on M4 Max
//  (fans slamming to max and back every few seconds around 95°C):
//
//  1. Hands-off profiles never engage — Apple's own curve IS the safety in
//     that mode, and seizing control (Ftst=1 suppresses thermalmonitord) to
//     max fans on a single-core boost spike just fights macOS mid-thermal-event.
//  2. Engagement requires the peak sensor at/above the threshold for
//     `sustainTicks` CONSECUTIVE ticks — a momentary per-core spike (the
//     safetyPeakTemp is a max over all Tp/TG sensors) is not an emergency.
//  3. Release waits for the hysteresis point (threshold − hysteresis), and the
//     release band in between HOLDS max instead of handing control back at the
//     first sub-threshold tick.
//

import Foundation

public struct SafetyOverrideGate {
    /// Engage at/above this peak temperature (FanProfile.safetyTempThreshold).
    public let threshold: Float
    /// Release only below this (threshold − hysteresis).
    public let clearBelow: Float
    /// Consecutive hot ticks required to engage.
    public let sustainTicks: Int

    private var hotTicks = 0
    private var engaged = false

    /// - sustainTicks: caller converts FanProfile.safetySustainSeconds by its
    ///   tick interval. The default assumes the monitor's 100ms tick.
    public init(threshold: Float = FanProfile.safetyTempThreshold,
                hysteresis: Float = FanProfile.hysteresisDegrees,
                sustainTicks: Int = max(1, Int((FanProfile.safetySustainSeconds / 0.1).rounded()))) {
        self.threshold = threshold
        self.clearBelow = threshold - hysteresis
        self.sustainTicks = max(1, sustainTicks)
    }

    /// Forget the current episode so the next controlled tick must re-earn
    /// engagement through the full sustained-heat window. Used when the monitor is
    /// forced to re-take control after the helper recovers (forceReengage).
    public mutating func reset() {
        hotTicks = 0
        engaged = false
    }

    public enum Action: Equatable {
        /// Transition to maxed — apply setMax once.
        case engage
        /// Stay maxed (covers ≥ threshold AND the [clearBelow, threshold) release
        /// band) — no new command.
        case hold
        /// Cooled below clearBelow — resume normal profile control this tick.
        case release
        /// Override not involved this tick.
        case normal
    }

    public mutating func evaluate(handsOff: Bool, temp: Float) -> Action {
        // Hands-off profiles are exempt entirely: Apple owns the safety there.
        if handsOff {
            engaged = false
            hotTicks = 0
            return .normal
        }

        if temp >= threshold {
            hotTicks += 1
        } else {
            hotTicks = 0
        }

        if engaged {
            if temp < clearBelow {
                engaged = false
                hotTicks = 0
                return .release
            }
            return .hold
        }

        if hotTicks >= sustainTicks {
            engaged = true
            hotTicks = 0
            return .engage
        }
        return .normal
    }
}
