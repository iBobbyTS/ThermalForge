//
//  ThermalForge.swift
//  ThermalForge
//
//  CLI entry point — fan control for Apple Silicon MacBooks.
//

import ArgumentParser
import Darwin
import Foundation
import ThermalForgeCore

/// CLI entry point. The wrapper exists only to ignore SIGPIPE process-wide before
/// ArgumentParser dispatches: R4 requires a write to a peer that closed its end
/// (e.g. the helper restarting under us) to become a normal error, not a fatal
/// signal. `ThermalForge.main()` is ArgumentParser's generated entry point; this
/// enum must be the program's `@main` so the signal is set first.
@main
enum ThermalForgeMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        ThermalForge.main()
    }
}

struct ThermalForge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermalforge",
        abstract: "Fan control for Apple Silicon MacBooks",
        version: ThermalForgeVersion.current,
        subcommands: [
            Max.self,
            Auto.self,
            SetSpeed.self,
            Status.self,
            Discover.self,
            Watch.self,
            Log.self,
            BuildApp.self,
        ]
    )
}

// MARK: - Daemon version reconciliation

/// Warn (on stderr, non-blocking) if a background daemon from a different build
/// is running. The daemon is a long-lived launchd process; after `brew upgrade`
/// it keeps running the OLD binary until `thermalforge install` re-syncs it, so
/// the menu bar app can silently diverge from this CLI. Called by every
/// fan-affecting command. Advisory only — it never blocks the command.
func warnIfDaemonVersionMismatch() {
    guard ThermalForgeDaemon.isRunning else { return }

    // A legacy (pre-Phase-2) daemon can't answer the framed `version` request — but
    // its socket is up, so this is a real mismatch that MUST warn (this is the very
    // message telling the user to reinstall). Any other failure (daemon down /
    // transient) stays silent so we don't nag on a blip.
    let daemonVersion: String
    do {
        let response = try DaemonClient().request(DaemonRequest(verb: .version))
        // Both the `version` reply (ok) and an `unsupportedVersion` reply carry the
        // daemon's build; a response without one means a build we can't name.
        daemonVersion = response.version ?? "an older build"
        guard daemonVersion != ThermalForgeVersion.current else { return }
    } catch DaemonError.incompatibleDaemon {
        daemonVersion = "an older build"
    } catch {
        return
    }

    let message = """
        ⚠️  Version mismatch: the background daemon is running \(daemonVersion), \
        but this CLI is \(ThermalForgeVersion.current).
            They're from different installs, so the menu bar app may not behave \
        like the command line until you re-sync them.
            Fix it with one command:  sudo thermalforge install

        """
    FileHandle.standardError.write(Data(message.utf8))
}

/// Emit the single stderr warning (never silent, never doubled) for a routed
/// fan command: the specific consequence when the daemon is too old to do what
/// was asked, or a plain version-mismatch nudge when it routed fine but is a
/// different build. The router already did the one version query this needs.
func reportRoute(_ route: FanRoute) {
    let message: String
    switch route {
    case .direct:
        return
    case .daemon(let version):
        // Routed and honored. Warn only if the daemon is a different build than
        // this CLI — the command worked, but the menu bar app may differ.
        let daemonVersion = version ?? "an older build"
        guard daemonVersion != ThermalForgeVersion.current else { return }
        message = """
            ⚠️  Version mismatch: the background daemon is running \(daemonVersion), \
            but this CLI is \(ThermalForgeVersion.current).
                The command was applied, but the menu bar app may not behave like \
            the command line until you re-sync.
                Fix it with one command:  sudo thermalforge install

            """
    case .daemonHoldWillRevert(let version):
        message = """
            ⚠️  The background daemon (\(version)) is too old to hold this without \
            supervision — it will revert to auto in about 15 seconds.
                Re-sync to make holds stick:  sudo thermalforge install

            """
    case .directOldDaemon(let version):
        message = """
            ⚠️  The background daemon (\(version)) is too old to route per-fan \
            commands, so this used a direct hardware write (which needs sudo).
                Re-sync to drop the sudo requirement:  sudo thermalforge install

            """
    case .directLegacyDaemon:
        message = """
            ⚠️  The background daemon is an older build that can't use the updated \
            control protocol, so this used a direct hardware write.
                Finish the upgrade to reconnect it:  sudo thermalforge install

            """
    }
    FileHandle.standardError.write(Data(message.utf8))
}

// MARK: - Max

struct Max: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "max",
        abstract: "Set all fans to maximum speed"
    )

    func run() throws {
        // Route through the daemon (no sudo) when it's running; oneshot so a
        // fire-and-forget max hold isn't reverted by the watchdog. The router
        // handles the version query and reportRoute the single mismatch warning.
        let (route, _, _) = try FanCommandRouter.apply(.setMax, oneshot: true)
        reportRoute(route)

        // Status readout is a read — works without root regardless of route.
        if let fc = try? FanControl(), let status = try? fc.status() {
            for fan in status.fans {
                print("Fan \(fan.index): \(fan.actualRPM) RPM → max (\(fan.maxRPM) RPM)")
            }
        }
    }
}

// MARK: - Auto

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Reset fans to Apple defaults"
    )

    @Flag(name: .long, help: """
        Also quit the menu bar app. A running app with an active profile
        re-applies its curve within seconds, so use --stop-app when the reset
        must STICK (e.g. handing control fully back to macOS). Leave it off — the
        default — when a script, benchmark, or inference run just needs to restore
        fans without closing the user's app.
        """)
    var stopApp: Bool = false

    func run() throws {
        // Only quit the menu bar app when explicitly asked. A plain fan reset must
        // not close the user's app as a side effect — callers that shell out to
        // restore fans (scripts, benchmark harnesses) would otherwise silently
        // lose their GUI. The app-override concern is real, so it's preserved
        // behind --stop-app rather than removed.
        if stopApp {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["ThermalForgeApp"]
            try? kill.run()
            kill.waitUntilExit()
        }

        // Route through the daemon (coordinates its state, no sudo) when running;
        // resetAuto isn't a hold, so oneshot doesn't apply.
        let (route, _, _) = try FanCommandRouter.apply(.resetAuto, oneshot: false)
        reportRoute(route)
        print(stopApp
            ? "Menu bar app stopped; fans reset to Apple defaults"
            : "Fans reset to Apple defaults")
    }
}

// MARK: - Set

struct SetSpeed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set fan speed to a specific RPM"
    )

    @Argument(help: "Target RPM")
    var rpm: Int

    @Option(name: .shortAndLong, help: "Fan index (default: all fans)")
    var fan: Int?

    /// Printed instead of a "Fan N → X RPM" line when a daemon applied the command but
    /// is too old (pre-0.2.1) to report the RPM it clamped to. We echo the value the
    /// daemon says it applied — never a target-register read-back (it lags a command
    /// ~1s) and never the raw request as if the daemon confirmed it. On the direct
    /// (no-daemon) path the request IS authoritative, because FanControl throws on an
    /// out-of-range value rather than clamping. When neither holds, we say the value is
    /// unknown rather than print a number we can't vouch for.
    private static let appliedUnknownByOldDaemon = """
        Fan speed set, but the background daemon is an older build that doesn't report \
        the applied RPM, so the exact value can't be shown. Re-sync to fix:
          sudo thermalforge install
        """

    func run() throws {
        let target = Float(rpm)

        if let index = fan {
            // Per-fan now routes through the daemon too (0.1.5 `setfan`); older
            // daemons fall back to direct SMC, which reportRoute flags.
            let (route, note, applied) = try FanCommandRouter.apply(.setFan(index: index, rpm: target), oneshot: true)
            reportRoute(route)
            if let note { print(note) }
            if let shown = applied ?? (route.wentThroughDaemon ? nil : rpm) {
                print("Fan \(index) → \(shown) RPM")
            } else {
                print(Self.appliedUnknownByOldDaemon)
            }
        } else {
            let (route, note, applied) = try FanCommandRouter.apply(.setRPM(target), oneshot: true)
            reportRoute(route)
            if let note { print(note) }
            if let shown = applied ?? (route.wentThroughDaemon ? nil : rpm) {
                if let fc = try? FanControl(), let count = try? fc.fanCount() {
                    for i in 0..<count {
                        print("Fan \(i) → \(shown) RPM")
                    }
                } else {
                    print("All fans → \(shown) RPM")
                }
            } else {
                print(Self.appliedUnknownByOldDaemon)
            }
        }
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print current fan speeds and temperatures as JSON"
    )

    func run() throws {
        let fc = try FanControl()
        let status = try fc.status()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try encoder.encode(status)
        print(String(data: json, encoding: .utf8)!)
    }
}

// MARK: - Discover

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Dump all SMC keys (run first on new hardware)"
    )

    @Option(name: .shortAndLong, help: "Filter keys by prefix (e.g., F for fans, T for temps)")
    var filter: String?

    @Option(name: .shortAndLong, help: "Write output to file")
    var output: String?

    func run() throws {
        let fc = try FanControl()
        let keys = fc.discover(prefix: filter)

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machineModel = String(cString: modelBuf)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var lines: [String] = []
        lines.append("ThermalForge Key Dump")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Machine: \(machineModel)")
        lines.append("macOS: \(osVersion)")
        lines.append("Keys found: \(keys.count)")
        lines.append(String(repeating: "\u{2500}", count: 72))
        lines.append("Key    Type   Size  Value")
        lines.append(String(repeating: "\u{2500}", count: 72))

        for entry in keys {
            let hex = entry.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")

            var note = ""
            if entry.size == 4 && entry.bytes.count >= 4 && entry.type == "flt " {
                let floatVal = smcBytesToFloat(entry.bytes, size: entry.size)
                if entry.key.hasPrefix("F") && floatVal >= 0 && floatVal <= 10000 {
                    note = " = \(Int(floatVal)) RPM"
                } else if entry.key.hasPrefix("T") && floatVal > 0 && floatVal < 150 {
                    note = " = \(String(format: "%.1f", floatVal)) C"
                }
            } else if entry.size == 8 && entry.bytes.count >= 4 && entry.type == "ioft" {
                let floatVal = ioftBytesToFloat(entry.bytes)
                if floatVal > 0 && floatVal < 150 {
                    note = " = \(String(format: "%.1f", floatVal)) C"
                }
            } else if entry.size == 1 && !entry.bytes.isEmpty {
                note = " = \(entry.bytes[0])"
            }

            let key = entry.key.padding(toLength: 6, withPad: " ", startingAt: 0)
            let type = entry.type.padding(toLength: 6, withPad: " ", startingAt: 0)
            let sizeStr = String(repeating: " ", count: max(0, 4 - "\(entry.size)".count)) + "\(entry.size)"
            lines.append("\(key) \(type) \(sizeStr)  \(hex)\(note)")
        }

        let report = lines.joined(separator: "\n")

        if let path = output {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(keys.count) keys to \(path)")
        } else {
            print(report)
        }
    }
}

// MARK: - Watch

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Monitor temps and auto-adjust fans based on a profile"
    )

    @Option(name: .shortAndLong, help: "Profile: silent, balanced, performance, max")
    var profile: String = "balanced"

    @Option(name: .shortAndLong, help: "Poll interval in seconds (default 0.1 = 100ms)")
    var interval: Double = 0.1

    @Flag(name: .long, help: "Output JSON on each update")
    var json: Bool = false

    func run() throws {
        warnIfDaemonVersionMismatch()
        let profiles = FanProfile.builtIn
        guard let selectedProfile = profiles.first(where: { $0.id == profile }) else {
            throw ValidationError(
                "Unknown profile '\(profile)'. Options: \(profiles.map(\.id).joined(separator: ", "))"
            )
        }

        let fc = try FanControl()
        let monitor = ThermalMonitor(fanControl: fc, profile: selectedProfile)

        print("ThermalForge watch — profile: \(selectedProfile.name)")
        print("Hardware: \(fc.hardwareInfo)")
        print("Polling every \(interval)s. Ctrl-C to stop.\n")

        // CLI runs as root, so fan commands go directly through FanControl
        monitor.onFanCommand = { command in
            switch command {
            case .setMax: try fc.setMax()
            case .setRPM(let rpm): try fc.setAllFans(rpm: rpm)
            case .setFan(let index, let rpm): try fc.setSpeed(fan: index, rpm: rpm)
            case .resetAuto: try fc.resetAuto()
            }
        }

        monitor.onUpdate = { [json] status, activeProfile, state in
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                if let data = try? encoder.encode(status),
                   let line = String(data: data, encoding: .utf8)
                {
                    print(line)
                }
            } else {
                let cpuTemp = status.temperatures
                    .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                    .values.max() ?? 0
                let gpuTemp = status.temperatures
                    .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }
                    .values.max() ?? 0
                let fan0 = status.fans.first.map { $0.actualRPM } ?? 0
                let stateLabel: String
                switch state {
                case .idle: stateLabel = "idle"
                case .active(let name): stateLabel = name
                case .safetyOverride: stateLabel = "SAFETY"
                }
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("[\(timestamp)] CPU: \(String(format: "%.0f", cpuTemp))°C  GPU: \(String(format: "%.0f", gpuTemp))°C  Fan: \(fan0) RPM  [\(stateLabel)]")
            }
        }

        // Set up signal handler for clean shutdown
        signal(SIGINT) { _ in
            print("\nResetting fans to auto...")
            if let resetFC = try? FanControl() {
                try? resetFC.resetAuto()
            }
            Darwin.exit(0)
        }

        monitor.start(interval: interval)

        // Keep the process alive
        RunLoop.main.run()
    }
}

// MARK: - Log

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Record thermal data to CSV for research and analysis"
    )

    /// Static reference for SIGINT handler (can't capture context in C function pointer)
    nonisolated(unsafe) static var activeLogger: ThermalLogger?

    @Option(name: .shortAndLong, help: "Sample rate in Hz (default: 1)")
    var rate: Double = 1.0

    @Option(name: .shortAndLong, help: "Duration (e.g., 1h, 30m, 60s). Omit for indefinite.")
    var duration: String?

    @Option(name: .shortAndLong, help: "Output directory (default: ~/Library/Application Support/ThermalForge/logs)")
    var output: String?

    @Flag(name: .long, help: "Keep logs permanently (default: auto-delete after 24h)")
    var noExpire: Bool = false

    func run() throws {
        let fc = try FanControl()

        let durationSec: TimeInterval? = duration.flatMap { parseDuration($0) }
        let outputURL = output.map { URL(fileURLWithPath: $0) }

        let logger = try ThermalLogger(
            fanControl: fc,
            rateHz: rate,
            duration: durationSec,
            outputDir: outputURL,
            noExpire: noExpire
        )

        // Clean expired sessions on startup
        ThermalLogger.cleanExpired()

        let durationStr = durationSec.map { formatDuration($0) } ?? "indefinite"
        print("ThermalForge Log")
        print("  Rate: \(rate) Hz")
        print("  Duration: \(durationStr)")
        print("  Output: \(logger.outputPath.path)")
        print("  Auto-delete: \(noExpire ? "off" : "after 24h")")
        print("\nLogging... Ctrl-C to stop.\n")

        // Clean shutdown on Ctrl-C
        Log.activeLogger = logger
        signal(SIGINT) { _ in
            print("\n\nStopping...")
            Log.activeLogger?.stop()
            Thread.sleep(forTimeInterval: 1)
            Darwin.exit(0)
        }

        logger.onSample = { line in
            print(line)
        }

        try logger.run()

        print("\nLog saved to: \(logger.outputPath.path)")
        print("  thermal.csv   — sensor readings + fan state")
        print("  processes.csv — top processes by CPU")
        print("  metadata.json — session info + data dictionary")
    }

    private func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("h"), let v = Double(trimmed.dropLast()) { return v * 3600 }
        if trimmed.hasSuffix("m"), let v = Double(trimmed.dropLast()) { return v * 60 }
        if trimmed.hasSuffix("s"), let v = Double(trimmed.dropLast()) { return v }
        return Double(trimmed)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        if t >= 3600 { return "\(Int(t / 3600))h" }
        if t >= 60 { return "\(Int(t / 60))m" }
        return "\(Int(t))s"
    }
}

// MARK: - BuildApp (internal)

/// Assembles ThermalForge.app from a built app binary + icon, writing the
/// Info.plist from ThermalForgeVersion.current. This is the SINGLE place the
/// bundle is assembled — both install paths (Homebrew formula and setup.sh)
/// call it, so no field (version included) can drift between them.
struct BuildApp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-app",
        abstract: "Assemble ThermalForge.app from a built app binary and icon (internal)",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Path to the built ThermalForgeApp executable")
    var binary: String

    @Option(name: .long, help: "Path to the .icns app icon")
    var icon: String

    @Option(name: .long, help: "Destination .app bundle path (created or replaced)")
    var dest: String

    func run() throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: binary) else {
            throw ValidationError("App binary not found: \(binary)")
        }
        guard fm.fileExists(atPath: icon) else {
            throw ValidationError("Icon not found: \(icon)")
        }

        let contents = "\(dest)/Contents"
        let macOSDir = "\(contents)/MacOS"
        let resources = "\(contents)/Resources"

        // Replace any existing bundle so a rebuild is clean.
        if fm.fileExists(atPath: dest) {
            try fm.removeItem(atPath: dest)
        }
        try fm.createDirectory(atPath: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: resources, withIntermediateDirectories: true)

        try fm.copyItem(atPath: binary, toPath: "\(macOSDir)/ThermalForgeApp")
        try fm.copyItem(atPath: icon, toPath: "\(resources)/AppIcon.icns")

        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleName</key>
                <string>ThermalForge</string>
                <key>CFBundleDisplayName</key>
                <string>ThermalForge</string>
                <key>CFBundleIdentifier</key>
                <string>com.thermalforge.app</string>
                <key>CFBundleVersion</key>
                <string>\(ThermalForgeVersion.current)</string>
                <key>CFBundleShortVersionString</key>
                <string>\(ThermalForgeVersion.current)</string>
                <key>CFBundleExecutable</key>
                <string>ThermalForgeApp</string>
                <key>CFBundleIconFile</key>
                <string>AppIcon</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>LSMinimumSystemVersion</key>
                <string>\(ThermalForgeVersion.minimumMacOS)</string>
                <key>LSUIElement</key>
                <true/>
                <key>NSHighResolutionCapable</key>
                <true/>
            </dict>
            </plist>
            """
        try plist.write(toFile: "\(contents)/Info.plist", atomically: true, encoding: .utf8)

        print("Assembled \(dest) (version \(ThermalForgeVersion.current))")
    }
}
