//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Dual-cadence design:
//  - Thermal tick (100ms): read temps, calculate curve, apply ramp governor, write fan speed
//  - Monitor tick (2s): process capture, anomaly detection, history logging
//

import Darwin
import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    case setRPM(Float)
    case setFan(index: Int, rpm: Float)
    case resetAuto

    /// A hold keeps fans at a manual setting (so an unsupervised one-shot could
    /// be reverted by the watchdog); resetAuto hands control back and isn't held.
    public var isHold: Bool {
        switch self {
        case .setMax, .setRPM, .setFan: return true
        case .resetAuto: return false
        }
    }

    /// Per-fan commands need the 0.1.5 `setfan` socket verb; older daemons
    /// reject them, so the router must version-gate and fall back to direct SMC.
    public var isPerFan: Bool {
        if case .setFan = self { return true }
        return false
    }
}

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    private let tickInterval: Float

    /// Monitor cadence: process capture + anomaly detection every N thermal ticks.
    /// At 100ms thermal tick, 20 × 0.1s = 2 seconds.
    private static let monitorCadence = 20

    /// UI update cadence: onUpdate fires every N thermal ticks.
    /// At 100ms thermal tick, 5 × 0.1s = 500ms — smooth UI without excessive redraws.
    private static let uiUpdateCadence = 5

    private var tickCounter = 0

    // MARK: - Fan State

    /// Owns the current-speed trajectory toward each tick's curve target
    /// (PT1 exponential approach). See FanSpeedController.
    private var speedController = FanSpeedController()
    /// What was last actually SENT to the fans, for the write deadband.
    private var lastWrittenRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    /// One-shot: the next tick must issue a write even if the deadband would
    /// otherwise suppress it. Armed by forceReengage; cleared ONLY when a tick
    /// actually issues a control write (the safety-engage setMax, a setRPM from
    /// tickCurve, or a resetAuto that hands the fans back to the system). A tick
    /// that returns without writing — cold/hands-off/hysteresis, a safety hold, a
    /// failed status read — leaves it armed so the next tick that CAN write does.
    private var forceNextWrite = false

    // MARK: - Safety Override

    /// Decides engage/hold/release for the 95°C override (hands-off exemption,
    /// sustained-heat filter, real release hysteresis). See SafetyOverrideGate.
    private var safetyGate = SafetyOverrideGate()

    // MARK: - Fans-Off Gate

    /// Decides hold/release for the fans-off transition: sustained-cold
    /// confirmation, so idle-core sensor cliffs can't bang-bang the release
    /// across stopTemp. See FanOffGate.
    private var fanOffGate = FanOffGate()

    // MARK: - Anomaly Detection

    /// Tracks temps over 30 seconds (15 readings at 2s monitor cadence)
    private var anomalyHistory: [Float] = []

    // MARK: - Process Buffer

    /// Rolling buffer — captures what was running BEFORE a spike.
    /// 15 snapshots × 2 seconds = 30 seconds of pre-spike history.
    private var processBuffer: [(timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()

    /// Called on UI update cadence (every 500ms) with updated status
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(fanControl: FanControl, profile: FanProfile = .silent) {
        self.fanControl = fanControl
        self.activeProfile = profile
        self.tickInterval = 0.1
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 0.1) {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Update the active profile. Switching itself sends no fan command: the
    /// next tick computes the new profile's target from the current temperature
    /// and the speed controller moves toward it — so the tracked fan state must
    /// stay truthful here. It is cleared only via resetFanState, at the places
    /// that actually send a resetAuto and hand fans back to the system.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile
        }
    }

    /// Forget the tracked fan state — call exactly where a resetAuto is sent:
    /// that's the only moment fans are handed back to the system.
    public func resetFanState() {
        queue.async { [self] in
            fansCurrentlyRunning = false
            speedController.reset()
            lastWrittenRPMPercent = 0
        }
    }

    /// Force the NEXT tick to unconditionally re-take fan control. Used after the
    /// helper recovers: it exited through its `.restart` resetAuto path, so the
    /// fans are back in Apple auto and any app hold the helper recorded is gone.
    /// The monitor must rebuild both its tracked runtime state and a fresh daemon
    /// hold. Resets the crash/off state, the speed controller, and the safety and
    /// fans-off gates (re-engagement then happens naturally on the next tick:
    /// still-hot re-earns the override through the sustain window; normal temps go
    /// through the bumpless-takeover branch), and arms a one-shot flag that defeats
    /// the write deadband so one real setRPM/setMax is issued.
    public func forceReengage() {
        queue.async { [self] in
            fansCurrentlyRunning = false
            speedController.reset()
            safetyGate.reset()
            fanOffGate.reset()
            // Impossible sentinel: |appliedPct - (-1)| is always greater than the
            // deadband, so the first tick's write can't be suppressed. tickCurve's
            // seed block must NOT overwrite this while forceNextWrite is set.
            lastWrittenRPMPercent = -1
            forceNextWrite = true
        }
    }

    // MARK: - Polling

    private func tick() {
        guard let status = try? fanControl.status() else { return }
        latestStatus = status

        // Snapshot a pending forced re-take for this tick. The property itself is
        // cleared only once this tick issues a real control write (below); a failed
        // status read above returned before reaching here, keeping it armed.
        let forceWrite = forceNextWrite

        // Peak CPU (TC/Tp) + GPU (TG/Tg) — the shared safety-floor sensor extraction,
        // so the client monitor and the daemon's floor read the identical value.
        let maxTemp = status.safetyPeakTemp

        // Monitor cadence: process capture + anomaly detection (every 2 seconds)
        if tickCounter % Self.monitorCadence == 0 {
            monitorTick(status: status, maxTemp: maxTemp)
        }

        // Safety override — decided by the pure SafetyOverrideGate: hands-off
        // profiles never engage (Apple's own curve is the safety there),
        // engagement needs SUSTAINED heat (a single-core boost spike is not an
        // emergency), and release waits for the hysteresis point — the [90, 95)
        // band HOLDS max instead of handing control back at the first
        // sub-threshold tick (the Silent-mode bang-bang this replaces).
        let safetyAction = safetyGate.evaluate(handsOff: activeProfile.curve.handsOff, temp: maxTemp)

        if safetyAction == .engage {
            applyCommand(.setMax)
            state = .safetyOverride
            fansCurrentlyRunning = true
            speedController.resync(1.0)
            lastWrittenRPMPercent = 1.0
            forceNextWrite = false   // the forced re-take was satisfied by this setMax
            TFLogger.shared.safety(
                "Override triggered: \(String(format: "%.1f", maxTemp))°C sustained "
                    + "\(Int(FanProfile.safetySustainSeconds.rounded()))s — fans maxed [\(activeProfile.name)]"
            )
        }

        if safetyAction == .engage || safetyAction == .hold {
            if tickCounter % Self.uiUpdateCadence == 0 {
                onUpdate?(status, activeProfile, state)
            }
            tickCounter += 1
            return
        }

        if safetyAction == .release {
            state = .idle
            TFLogger.shared.safety(
                "Override cleared at \(String(format: "%.1f", maxTemp))°C — resuming \(activeProfile.name)"
            )
            // Fall through: tickCurve resumes the profile, and the speed
            // controller eases fans off max instead of dropping them.
        }

        // tickCurve clears forceNextWrite itself, and only at the points where it
        // actually issues a control write (setRPM or a release resetAuto). Every
        // early return above leaves the flag armed for the next writable tick.
        tickCurve(status: status, peakTemp: maxTemp, forceWrite: forceWrite)

        // UI update at slower cadence (every 500ms)
        if tickCounter % Self.uiUpdateCadence == 0 {
            onUpdate?(status, activeProfile, state)
        }

        tickCounter += 1
    }

    // MARK: - Monitor Cadence (every 2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Runs at 2-second intervals to avoid sysctl overhead at 100ms.
    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        // Rolling process buffer — always capturing, like a security camera
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        // Anomaly detection: two tiers
        // Tier 1: instant spike — >5°C between consecutive readings (2 seconds)
        // Tier 2: sustained change — >10°C over 30 seconds
        var spikeDetected = false

        // Tier 1: check against previous reading
        if let prevTemp = anomalyHistory.last {
            let instantDelta = maxTemp - prevTemp
            if abs(instantDelta) > 5 {
                let direction = instantDelta > 0 ? "spike" : "drop"
                let fan0 = status.fans.first
                TFLogger.shared.info(
                    "Instant \(direction): \(String(format: "%.1f", prevTemp))→\(String(format: "%.1f", maxTemp))°C " +
                    "(\(String(format: "%+.1f", instantDelta))°C in 2s) | " +
                    "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                    "Profile: \(activeProfile.name)"
                )
                spikeDetected = true
            }
        }

        // Tier 2: check over 30-second window
        if anomalyHistory.count >= 15 {
            let oldest = anomalyHistory.first!
            let sustainedDelta = maxTemp - oldest
            if abs(sustainedDelta) > 10 {
                let direction = sustainedDelta > 0 ? "spike" : "drop"
                let fan0 = status.fans.first
                TFLogger.shared.info(
                    "Sustained \(direction): \(String(format: "%.1f", oldest))→\(String(format: "%.1f", maxTemp))°C " +
                    "(\(String(format: "%+.1f", sustainedDelta))°C in 30s) | " +
                    "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                    "Profile: \(activeProfile.name)"
                )
                spikeDetected = true
                anomalyHistory.removeAll()
            }
        }

        // Dump the rolling buffer on any spike — shows what was running BEFORE
        if spikeDetected {
            TFLogger.shared.info("Pre-spike process history (last \(processBuffer.count * 2)s):")
            for entry in processBuffer {
                TFLogger.shared.info("  \(entry.timestamp): \(entry.processes)")
            }
        }

        anomalyHistory.append(maxTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(status: ThermalStatus, peakTemp: Float, forceWrite: Bool) {
        let curve = activeProfile.curve
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        // Hands-off profiles (Silent): don't control fans, just monitor
        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                speedController.reset()
                lastWrittenRPMPercent = 0
                state = .idle
                // resetAuto is a real control action (fans handed to the system),
                // so a pending forced re-take is satisfied here.
                forceNextWrite = false
            }
            // Not running → nothing to write: keep forceNextWrite armed.
            return
        }

        // Fans-off gate — evaluated EVERY tick (like the safety gate) so its
        // cold streak resets the moment the peak leaves the stop band.
        let offAction = fanOffGate.evaluate(temp: peakTemp, stopTemp: curve.stopTemp)

        // Get target from curve (now applies curve shape: easeIn, linear, easeOut, sCurve)
        let curveTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning)

        if curveTarget == nil {
            // Curve says fans should be off — but the release is CONFIRMED, not
            // instant: an idle core's sensor reading falls off a cliff when its
            // workload ends, swinging the peak across stopTemp on a 100ms scale.
            // An instant release there handed the fans to Apple mid-ramp over
            // and over (2,182 releases in three days of logs — the sudden
            // 3000+→1300 RPM drops). Until cold is sustained, hold at minimum —
            // the same treatment the hysteresis band gives.
            // Not running → nothing to write: keep forceNextWrite armed.
            guard fansCurrentlyRunning else { return }
            if offAction == .release {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                speedController.reset()
                lastWrittenRPMPercent = 0
                state = .idle
                // resetAuto is a real control action (fans handed to the system).
                forceNextWrite = false
                TFLogger.shared.fan(
                    "Fans off: \(String(format: "%.1f", peakTemp))°C sustained "
                        + "≤\(Int(curve.stopTemp))°C for \(Int(FanProfile.stopSustainSeconds.rounded()))s "
                        + "[\(activeProfile.name)]"
                )
                return
            }
            // Cold not yet confirmed — hold at minimum, like the hysteresis band.
        }

        // 0.001 signals "keep at minimum" (hysteresis band + unconfirmed cold)
        let rawTarget = curveTarget ?? 0.001
        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget

        // Clamp to valid range
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Bumpless transfer: taking over from Apple auto, seed the controller
        // from the OBSERVED speed. Assuming a standstill would hand the first
        // tick a huge error and slam the fans; seeding reality makes the
        // takeover continuous with whatever macOS was doing.
        if !fansCurrentlyRunning {
            let observedPct = status.fans.first.map { Float($0.actualRPM) / maxRPM } ?? 0
            let seed = min(max(observedPct, minRPM / maxRPM), 1)
            speedController.resync(seed)
            // On a forced re-take, leave lastWrittenRPMPercent at the -1 sentinel
            // forceReengage set: overwriting it with the seed would exactly cancel
            // the deadband check below when observed ≈ target, suppressing the one
            // write that rebuilds the daemon's hold.
            if !forceWrite {
                lastWrittenRPMPercent = seed
            }
        }

        // Speed controller — PT1 approach, one step toward the target.
        // instantEngage keeps its contract: upward jumps bypass the controller
        // entirely; downward always glides.
        if curve.instantEngage && targetPct > speedController.current {
            speedController.resync(targetPct)
        } else {
            _ = speedController.advance(target: targetPct, dt: tickInterval)
        }

        // Apply if changed meaningfully (threshold scaled for 100ms ticks). A forced
        // re-take always writes once, so the deadband can't skip the takeover.
        let appliedPct = speedController.current
        if forceWrite || abs(appliedPct - lastWrittenRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * appliedPct, minRPM)
            applyCommand(.setRPM(targetRPM))
            // A real control write was issued — the forced re-take is satisfied.
            forceNextWrite = false

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            lastWrittenRPMPercent = appliedPct
            fansCurrentlyRunning = true
            state = .active(profileName: activeProfile.name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: activeProfile.name)
        }
    }

    // MARK: - Process Capture

    /// Capture top 5 processes by CPU for anomaly logging
    private func captureTopProcesses() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return "unavailable" }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [(name: String, cpu: Double)] = []

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0.1 {
                results.append((name, cpuPct))
            }
        }

        let top5 = results.sorted { $0.cpu > $1.cpu }.prefix(5)
        if top5.isEmpty { return "idle" }
        return top5.map { "\($0.name)(\(String(format: "%.1f", $0.cpu))%)" }.joined(separator: ", ")
    }

    // MARK: - Helpers

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }

}
