//
//  Profile.swift
//  ThermalForge
//
//  Fan control profiles with proportional temperature curves.
//
//  Each profile defines a curve that maps temperature to a TARGET fan speed;
//  the shared FanSpeedController (PT1 exponential approach, <=3s to any
//  target) owns how the current speed moves toward it.
//
//  Based on Apple fan hardware research:
//  - 0 to minimum RPM is binary (hardware limitation)
//  - Above minimum, proportional control with configurable curve shape
//  - Start/stop cycles are the #1 fan bearing wear factor
//  - At least 5°C hysteresis between start and stop thresholds
//  - The speed controller is acoustic comfort, not bearing protection
//

import Foundation

// MARK: - Curve Shape

/// How the profile maps temperature position to fan speed in the proportional zone.
public enum CurveShape: String, Codable, Equatable {
    /// pos * max — direct proportional response
    case linear
    /// pos² * max — quiet start, accelerates with heat
    case easeIn
    /// √pos * max — fast initial response, levels off
    case easeOut
    /// pos²(3-2pos) * max — smooth at both ends
    case sCurve
}

// MARK: - Profile Model

public struct FanProfile: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let curve: Curve

    /// Defines how the profile maps temperature to fan speed.
    public struct Curve: Codable, Equatable {
        /// Below this temperature, fans turn off — but only after
        /// stopSustainSeconds of sustained cold (see FanOffGate); an instant
        /// release would bang-bang on idle-core sensor cliffs.
        /// Must be at least 5°C below startTemp for hysteresis.
        public let stopTemp: Float

        /// Above this temperature, fans engage.
        public let startTemp: Float

        /// Temperature at which fan speed reaches maxRPMPercent.
        /// Ignored when instantEngage is true (binary on/off).
        public let ceilingTemp: Float

        /// Maximum fan speed as fraction of max RPM (0.0–1.0).
        public let maxRPMPercent: Float

        /// If true, this profile doesn't control fans — stays in Apple auto mode.
        public let handsOff: Bool

        /// If true, fans are always at maxRPMPercent regardless of temperature.
        public let alwaysOn: Bool

        /// How temperature maps to fan speed in the proportional zone.
        public let curveShape: CurveShape

        /// If true, skip the speed controller's ramp-up — jump directly to
        /// target. Ramp-down still goes through the controller.
        public let instantEngage: Bool

        public init(stopTemp: Float = 50, startTemp: Float = 55, ceilingTemp: Float = 70,
                    maxRPMPercent: Float = 0.6, handsOff: Bool = false, alwaysOn: Bool = false,
                    curveShape: CurveShape = .linear,
                    instantEngage: Bool = false) {
            self.stopTemp = stopTemp
            self.startTemp = startTemp
            self.ceilingTemp = ceilingTemp
            self.maxRPMPercent = maxRPMPercent
            self.handsOff = handsOff
            self.alwaysOn = alwaysOn
            self.curveShape = curveShape
            self.instantEngage = instantEngage
        }

        /// Calculate the target fan speed percentage (0.0–1.0) for a given temperature.
        /// Returns nil if fans should be off (Apple auto).
        /// Returns 0.001 as a signal to keep fans at minimum RPM (hysteresis band).
        public func targetPercent(at temp: Float, fansCurrentlyRunning: Bool) -> Float? {
            // Always-on profiles ignore temperature
            if alwaysOn { return maxRPMPercent }

            // Hands-off profiles don't control fans
            if handsOff { return nil }

            // Below stop threshold and fans not running: stay off
            if temp <= stopTemp && !fansCurrentlyRunning { return nil }

            // In hysteresis band (between stop and start): maintain current state
            if temp > stopTemp && temp < startTemp {
                return fansCurrentlyRunning ? 0.001 : nil // 0.001 signals "keep at minimum"
            }

            // Below stop threshold but fans are running: turn off
            if temp <= stopTemp && fansCurrentlyRunning { return nil }

            // Above start: apply curve shape
            if temp >= startTemp {
                if temp >= ceilingTemp { return maxRPMPercent }

                // Instant engage profiles jump directly to max (no proportional curve up)
                if instantEngage { return maxRPMPercent }

                let position = (temp - startTemp) / (ceilingTemp - startTemp)
                let shaped: Float
                switch curveShape {
                case .linear:
                    shaped = position
                case .easeIn:
                    shaped = position * position
                case .easeOut:
                    shaped = sqrt(position)
                case .sCurve:
                    shaped = position * position * (3 - 2 * position)
                }
                return shaped * maxRPMPercent
            }

            return nil
        }
    }

    public init(id: String, name: String, curve: Curve) {
        self.id = id
        self.name = name
        self.curve = curve
    }
}

// MARK: - Built-in Profiles

extension FanProfile {
    /// Silent (Apple Default): hands-off, let Apple control fans. ThermalForge monitors only.
    public static let silent = FanProfile(
        id: "silent",
        name: "Silent (Apple Default)",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 55,
                     maxRPMPercent: 0, handsOff: true)
    )

    /// Balanced: gentle ease-in curve for everyday use.
    /// Quiet at low temps (pos²), ramps harder as heat builds.
    public static let balanced = FanProfile(
        id: "balanced",
        name: "Balanced",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 70,
                     maxRPMPercent: 0.60, curveShape: .easeIn)
    )

    /// Performance: linear curve, fast response. Thermals over noise.
    public static let performance = FanProfile(
        id: "performance",
        name: "Performance",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 65,
                     maxRPMPercent: 0.85, curveShape: .linear)
    )

    /// Max: fans pinned at 100%, no temperature conditions. Selecting it means
    /// permanent max until another profile (or Default) takes over.
    public static let max = FanProfile(
        id: "max",
        name: "Max",
        curve: Curve(stopTemp: 50, startTemp: 65, ceilingTemp: 65,
                     maxRPMPercent: 1.0, alwaysOn: true, curveShape: .linear,
                     instantEngage: true)
    )

    public static let builtIn: [FanProfile] = [silent, balanced, performance, max]

    /// Resolve a persisted profile id to a known profile for launch restore. Returns
    /// Silent when the id is nil (nothing saved) or unrecognized (a profile removed or
    /// renamed in a later version — e.g. a save left over from the removed Smart
    /// profile), so a stale saved id never crashes.
    public static func selectable(id: String?) -> FanProfile {
        guard let id else { return .silent }
        return builtIn.first { $0.id == id } ?? .silent
    }
}

// MARK: - Persistence

extension FanProfile {
    private static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles")
    }

    public func save() throws {
        let dir = Self.profilesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    public static func loadAll() -> [FanProfile] {
        let dir = profilesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            return builtIn
        }

        var profiles = builtIn
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let profile = try? JSONDecoder().decode(FanProfile.self, from: data)
            {
                if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[idx] = profile
                } else {
                    profiles.append(profile)
                }
            }
        }
        return profiles
    }
}

// MARK: - Speed Control

extension FanProfile {
    /// PT1 approach time-constant, target ABOVE current (seconds). See
    /// FanSpeedController for the algorithm; the taus are sized from the 3s
    /// convergence deadline: tau <= 3 / ln(err0 / snap). Worst real span is
    /// min→max RPM (≈0.296→1.0 on this hardware, err0 ≈ 0.70), so with snap
    /// 0.01 the bound is tau <= 0.71 — 0.55 leaves margin (~2.4s worst case).
    public static let speedTauUpSeconds: Float = 0.55
    /// Same, target BELOW current. Slightly larger than up: the old governors'
    /// acoustic intent (gentle deceleration) kept, still ~2.8s worst case.
    public static let speedTauDownSeconds: Float = 0.65
    /// Land exactly on the target once within this fraction of max RPM —
    /// makes "reached target" exact instead of asymptotic.
    public static let speedSnapFraction: Float = 0.01
}

// MARK: - Safety

extension FanProfile {
    /// Hard safety threshold — overrides any profile
    public static let safetyTempThreshold: Float = 95.0
    /// Hysteresis deadband to prevent oscillation
    public static let hysteresisDegrees: Float = 5.0
    /// How long the peak sensor must STAY at/above the threshold before the
    /// safety override engages. Single P-core boost spikes touch 95°C+ for well
    /// under a second while the package is fine — Apple Silicon design behavior,
    /// not an emergency. Thermal mass makes a 2-second filter free in a real one.
    /// Shared by the client monitor (SafetyOverrideGate) and the daemon's floor.
    public static let safetySustainSeconds: Float = 2.0
    /// How long the peak sensor must STAY at/below stopTemp before fans are
    /// handed back to Apple's auto mode — the release-direction mirror of
    /// safetySustainSeconds. The peak is a max over all CPU/GPU cores, and an
    /// idle core's reading drops 20-30°C the instant its workload ends, so with
    /// stopTemp at idle-core resting level the peak oscillates across the
    /// threshold on a 100ms scale; an instant release there handed the fans to
    /// Apple mid-ramp 2,182 times in three days of logs (fans slamming
    /// 3000+→1300 RPM every 3-7 seconds — the start/stop cycling that is the
    /// #1 bearing wear factor). Until cold is confirmed, fans hold at minimum.
    public static let stopSustainSeconds: Float = 5.0
}
