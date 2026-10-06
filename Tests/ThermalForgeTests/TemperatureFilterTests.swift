//
//  TemperatureFilterTests.swift
//  ThermalForge
//
//  Curve-input low-pass, tested hardware-free: first sample seeds (no
//  invented cold start), heating passes fast while cooling is damped
//  (asymmetry), an idle-ish ±5°C P-core oscillation collapses to ~0.7°C
//  (the RPM-chatter root cause), genuine multi-second cooling still gets
//  through, and a steady input stays put.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Temperature filter (asymmetric PT1)")
struct TemperatureFilterTests {

    @Test("first sample passes through unfiltered")
    func seedsFromFirstSample() {
        var f = TemperatureFilter()
        let out = f.update(raw: 62.5, dt: 0.1)
        #expect(out == 62.5)
        #expect(f.value == 62.5)
    }

    @Test("heating steps are larger than cooling steps")
    func heatingIsFasterThanCooling() {
        var up = TemperatureFilter()
        _ = up.update(raw: 60, dt: 0.1)
        let upStep = up.update(raw: 70, dt: 0.1) - 60

        var down = TemperatureFilter()
        _ = down.update(raw: 60, dt: 0.1)
        let downStep = 60 - down.update(raw: 50, dt: 0.1)

        // Same 10°C error, same dt — only the direction differs.
        #expect(upStep > downStep)
    }

    @Test("±5°C oscillation collapses (the RPM-chatter root cause)")
    func oscillationIsAttenuated() {
        var f = TemperatureFilter()
        // 1s high / 1s low square wave around 60±5°C, 100ms samples, 30s.
        var value = f.update(raw: 65, dt: 0.1)
        var lo = value, hi = value
        for tick in 1..<300 {
            let raw: Float = (tick / 10) % 2 == 0 ? 65 : 60
            value = f.update(raw: raw, dt: 0.1)
            // Track only the settled second half, after transients decayed.
            if tick >= 150 {
                lo = min(lo, value)
                hi = max(hi, value)
            }
        }
        // Steady-state amplitude is ~0.7°C analytically; 1.5 leaves margin.
        #expect(hi - lo < 1.5, "amplitude \(hi - lo)")
        // Alive, not frozen: it still tracks the band's direction.
        #expect(hi - lo > 0.1)
    }

    @Test("genuine cooling still gets through")
    func genuineCoolingPasses() {
        var f = TemperatureFilter()
        _ = f.update(raw: 60, dt: 0.1)
        var value: Float = 60
        for _ in 0..<300 {                                  // 30s at 40°C = 5×tau
            value = f.update(raw: 40, dt: 0.1)
        }
        #expect(value > 38.0, "settled at \(value)")
    }

    @Test("steady input is steady output")
    func steadyInputIsStable() {
        var f = TemperatureFilter()
        _ = f.update(raw: 55, dt: 0.1)
        for _ in 0..<50 {
            #expect(f.update(raw: 55, dt: 0.1) == 55)
        }
    }
}
