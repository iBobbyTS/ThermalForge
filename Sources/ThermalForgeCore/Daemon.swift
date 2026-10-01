//
//  Daemon.swift
//  ThermalForge
//
//  Privileged daemon that runs as root via launchd.
//  Listens on a Unix socket so the app can control fans without sudo.
//

import Darwin
import Foundation
import IOKit.pwr_mgt

// MARK: - Constants

public enum ThermalForgeDaemon {
    // /var/run is root-owned 0755: unprivileged processes cannot create entries,
    // so path squatting is structurally impossible (unlike world-writable /tmp).
    // Cleared at boot; RunAtLoad re-creates the socket at daemon load.
    public static let socketPath = "/var/run/thermalforge.sock"
    public static let label = "com.thermalforge.daemon"

    /// Umask applied around bind() so the socket is created with its final mode
    /// atomically — no bind→chmod window in which a different mode is visible.
    /// A socket file is created 0777 & ~umask, so 0117 yields the intended 0660
    /// (rw-rw----). Public so a test can assert the mode math without a socket.
    public static let socketUmask: mode_t = 0o117

    /// The mode bind() yields under `socketUmask`, computed rather than hardcoded
    /// so the umask and the expected mode can't drift apart.
    public static let socketMode: mode_t = 0o777 & ~socketUmask

    /// Check if the daemon socket exists and accepts connections
    public static var isRunning: Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, socketPath)

        // Bounded connect: a wedged daemon (accept loop stalled, listen backlog
        // full) must make this return false — NOT hang. This is on the emergency
        // reset path: `sudo thermalforge auto` → FanCommandRouter.apply → this
        // guard; returning false there falls back to a direct root SMC reset, which
        // is exactly the right behavior when the daemon can't be reached. An
        // unbounded connect here would hang the one command that must always work.
        return connectWithTimeout(fd, &addr, timeout: 2.0)
    }
}

// MARK: - Daemon Client

public enum DaemonError: Error, CustomStringConvertible {
    case notRunning
    case connectionFailed
    case commandFailed(String)
    /// The running helper speaks the pre-Phase-2 string protocol (upgrade window:
    /// a new app bundle is in place but the old helper is still registered). Its
    /// socket is up so it isn't "not running" — callers must handle this distinctly
    /// (reopen guidance / direct-SMC fallback), not mistake it for a transient failure.
    case incompatibleDaemon

    public var description: String {
        switch self {
        case .notRunning:
            return "ThermalForge helper is not running. Reopen ThermalForge to re-register it, or check System Settings > General > Login Items & Extensions."
        case .connectionFailed:
            return "Failed to connect to helper socket"
        case .commandFailed(let msg):
            return "Daemon error: \(msg)"
        case .incompatibleDaemon:
            return "The background helper is an older build using the previous control protocol. Reopen ThermalForge to update the embedded helper, or check System Settings > General > Login Items & Extensions."
        }
    }
}

/// The daemon's current hold, returned by the `state` verb as JSON.
public struct DaemonHoldState: Codable, Equatable {
    /// The held fan command ("max", "set 3000", "setfan 1 3000"), or nil if none.
    public let command: String?
    /// Who set it: "cli" (unsupervised, never watchdog-reverted), "app"
    /// (supervised, reverted if the app stops checking in), or "none".
    public let owner: String
    /// True while the thermal floor is overriding this hold to max for safety. The
    /// `command` still reflects what the USER asked for (e.g. "set 2000"), never "max",
    /// so the app can say "held at 2000 — temporarily maxed for safety".
    public let safetySuspended: Bool

    public init(command: String?, owner: String, safetySuspended: Bool = false) {
        self.command = command
        self.owner = owner
        self.safetySuspended = safetySuspended
    }

    public var isEmpty: Bool { owner == "none" }
    public var isCLIHold: Bool { owner == "cli" }
}

/// The result of applying a fan command: the daemon's advisory note (e.g. a clamp)
/// and the RPM it actually applied. Both come straight from the daemon's response so
/// the CLI echoes the authoritative value, never a laggy target-register read-back.
public struct FanApplyResult: Equatable {
    public let note: String?
    public let appliedRPM: Int?
    public init(note: String?, appliedRPM: Int?) {
        self.note = note
        self.appliedRPM = appliedRPM
    }
}

public final class DaemonClient {
    public init() {}

    /// Read the daemon's current hold (what's set and who owns it) so the menu
    /// bar app can reflect a CLI hold instead of fighting or wiping it.
    public func readState() throws -> DaemonHoldState {
        let response = try request(DaemonRequest(verb: .state))
        guard response.ok, let state = response.state else {
            throw DaemonError.commandFailed("malformed state response")
        }
        return state
    }

    /// Ask the helper to exit so launchd (KeepAlive) respawns the freshly
    /// installed bundle binary. Mirrors `readState()`: one typed request, throws
    /// on transport failure, returns the decoded response. The daemon
    /// acknowledges with a plain `ok`; a daemon built before the `.restart` verb
    /// answers `.unsupportedVersion` (ok == false) rather than throwing, so the
    /// caller can fall back.
    @discardableResult
    public func restart() throws -> DaemonResponse {
        try request(DaemonRequest(verb: .restart))
    }

    /// Apply a `FanCommand`, throwing `commandFailed` on an error response.
    /// - oneshot: apply the command but do NOT arm the heartbeat watchdog — for
    ///   fire-and-forget CLI holds that must persist without a supervising process.
    ///   The menu bar app leaves this false so it stays supervised/crash-protected.
    ///   No effect on resetAuto (nothing to hold).
    @discardableResult
    public func execute(_ command: FanCommand, oneshot: Bool = false) throws -> FanApplyResult {
        let response = try request(DaemonRequest(command, oneshot: oneshot))
        guard response.ok else {
            throw DaemonError.commandFailed(
                response.message ?? response.error.map { String(describing: $0) } ?? "daemon error"
            )
        }
        // Note + applied RPM ride back on an OK response (e.g. a clamp).
        return FanApplyResult(note: response.note, appliedRPM: response.appliedRPM)
    }

    /// Send one typed request and return the typed response — length-prefixed JSON
    /// frames, no string protocol. Runs over the SAME bounded socket code as before
    /// (the v0.1.7 freeze fix): non-blocking `connectWithTimeout` plus
    /// SO_RCVTIMEO/SO_SNDTIMEO, so a wedged daemon can never block the caller.
    public func request(_ req: DaemonRequest, timeout: TimeInterval = 2.0) throws -> DaemonResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }

        // R4: a helper that exits (e.g. a `.restart`) between our connect and our
        // write must produce a FrameError.write, never a SIGPIPE that kills the
        // caller. This process-wide SIG_IGN is set at each entry point too; this
        // per-fd option is the guarantee that travels with the socket.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Bound every send/recv so a hung or contended daemon can never block the
        // caller indefinitely — the v0.1.7 freeze. Healthy round-trips here are
        // sub-millisecond (heartbeat/version/state) to low-single-digit ms; 2s is a
        // stall cutoff with wide margin over the heaviest real reply.
        let whole = Int(timeout)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((timeout - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        // connect() must ALSO be bounded, not just read/write. A wedged daemon
        // (accept loop stalled in a slow handleClient, listen backlog full) makes a
        // fresh connect() block indefinitely — and with the launch-adopt gate that
        // would silently leave the app with no fan control and no heartbeat. The
        // shared helper connects non-blocking, polls within `timeout`, and restores
        // blocking mode on success so SO_RCVTIMEO/SO_SNDTIMEO govern the frame I/O.
        guard connectWithTimeout(fd, &addr, timeout: timeout) else {
            throw DaemonError.notRunning
        }

        let frame = try DaemonProtocol.encodeFrame(req, max: DaemonProtocol.maxRequestBytes)
        try DaemonProtocol.writeFrame(fd, frame)
        do {
            let body = try DaemonProtocol.readFrame(fd, max: DaemonProtocol.maxResponseBytes)
            return try DaemonProtocol.decode(DaemonResponse.self, from: body)
        } catch DaemonProtocol.FrameError.legacyPeer {
            // A pre-Phase-2 daemon replied with a raw string; surface it distinctly so
            // callers can nudge a reinstall / fall back to direct SMC, not treat it as
            // a generic failure.
            throw DaemonError.incompatibleDaemon
        }
    }
}

// MARK: - Hold State

/// The daemon's current fan hold. Distinguishes an unsupervised CLI hold (never
/// watchdog-reverted — a fire-and-forget `thermalforge max`) from a supervised
/// app hold (reverted if the app stops checking in). These are the two states
/// the old single `lastHeartbeat: Date?` nil conflated, which is why an app
/// heartbeat silently re-armed the watchdog against a CLI oneshot hold (v0.1.5).
private enum HoldState {
    case none
    case unsupervised(command: String)
    case supervised(command: String, lastBeat: Date)

    /// The held command string ("max" / "set 3000" / "setfan 1 3000"), for
    /// wake re-apply. nil when nothing is held.
    var command: String? {
        switch self {
        case .none: return nil
        case .unsupervised(let c), .supervised(let c, _): return c
        }
    }

    func snapshot(safetySuspended: Bool = false) -> DaemonHoldState {
        switch self {
        case .none: return DaemonHoldState(command: nil, owner: "none", safetySuspended: safetySuspended)
        case .unsupervised(let c): return DaemonHoldState(command: c, owner: "cli", safetySuspended: safetySuspended)
        case .supervised(let c, _): return DaemonHoldState(command: c, owner: "app", safetySuspended: safetySuspended)
        }
    }
}

// MARK: - Daemon Server

public final class DaemonServer {
    private let socketFD: Int32
    private let fanControl: FanControl
    /// Serializes all SMC access — prevents data race between client handler and watchdog
    private let smcLock = NSLock()
    /// The current hold and its owner. Re-applied after sleep/wake; the watchdog
    /// reverts it only when it's `.supervised` and the app has gone silent.
    private var hold: HoldState = .none
    /// True while the thermal floor is overriding a hold to max. Guarded by stateLock.
    private var safetySuspended = false
    private let stateLock = NSLock()

    /// Per-fan [min, max] RPM, cached at init (fixed hardware constants) for clamping
    /// `set`/`setfan` — so a hostile value can't drive the SMC out of range.
    private let fanLimits: [(min: Float, max: Float)]
    /// Flood protection for SMC-writing verbs (`auto`/reset exempt). Guarded by rateLock.
    private var rateLimiter: RateLimiter
    private let rateLock = NSLock()
    /// The thermal safety floor's decision logic (thresholds mirrored from FanProfile).
    private let thermalFloor = ThermalFloor()
    /// A temperature sampler injected by tests. When nil, the floor reads the SMC
    /// safety keys itself — per key under smcLock — so it unit-tests via ThermalFloor
    /// and runs without head-of-line blocking in production.
    private let injectedSampler: (() -> Float?)?

    /// Phase 4 connection layer (concurrent bounded accept + framed I/O), created in run().
    private var connectionServer: ConnectionServer?

    /// One-shot guard for `.restart` shutdown. Both the response-write completion
    /// and the 5s fallback timer can call it; whichever runs first wins, and the
    /// other becomes a no-op rather than a second `exit`.
    private let restartLock = NSLock()
    private var restartScheduled = false

    public init(fanControl: FanControl,
                sampleMaxTemp: (() -> Float?)? = nil) throws {
        self.fanControl = fanControl
        // Cache fan RPM limits once (fixed hardware constants). Empty on a read failure
        // → clamp becomes a no-op and FanControl's own range check stays the backstop.
        self.fanLimits = (try? fanControl.status())?.fans
            .map { (Float($0.minRPM), Float($0.maxRPM)) } ?? []
        self.rateLimiter = RateLimiter(now: Date())
        self.injectedSampler = sampleMaxTemp

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.socketFD = fd

        // Remove stale socket (safe now: only root can have created anything in
        // root-owned /var/run — no unprivileged squatter to preserve).
        unlink(ThermalForgeDaemon.socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        // Bind under a 0117 umask so the socket is 0660-from-birth — the previous
        // bind→chmod gap (default umask briefly left the socket more permissive)
        // never exists. A socket file is created 0777 & ~umask, so this yields
        // exactly 0660 (rw-rw----) before any connect can race the chmod below.
        // Restore the process umask immediately after.
        //
        // Owner model (replaces the old chown-to-installing-uid + 0600 model):
        // the socket is root:admin 0660. Any member of the `admin` group may
        // connect — group membership already grants sudo-equivalent control, so
        // this is not a privilege escalation — while non-admin users are denied by
        // the group bits. root owns the file, so no unprivileged account can
        // replace or unlink it. This removes the old installer's need to capture
        // the controlling user's uid and the lockout that followed if that account
        // changed.
        let oldMask = umask(ThermalForgeDaemon.socketUmask)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bindResult == 0 else {
            close(fd)
            throw ThermalForgeError.writeFailed("bind() failed: \(errno)")
        }

        // Resolve the admin group by NAME — never a hardcoded gid (80 is not
        // guaranteed across systems/installs). Fail loudly if it can't be found:
        // proceeding would chown to the wrong group and silently lock every admin
        // user out of fan control (a mystery "helper-down" banner, no cause).
        guard let adminGroup = getgrnam("admin") else {
            let err = errno
            NSLog("ThermalForge daemon: getgrnam(\"admin\") failed: errno %d — cannot set socket group", err)
            close(fd)
            throw ThermalForgeError.writeFailed("getgrnam(admin) failed: errno \(err)")
        }
        let adminGID = adminGroup.pointee.gr_gid

        // Refinement on top of the 0660-from-birth umask above: chown so the
        // socket's group is `admin` (rather than the creating process's group) so
        // admin users can connect, and chmod to make the intended mode explicit.
        // Neither call is the security boundary; if it fails we still fail closed
        // (a failed chown leaves the socket root-owned, reachable by root only) and
        // we guard them for DIAGNOSABILITY — an unchecked failure would surface as a
        // mystery "helper-down" banner with no cause. A loud crash-loop under
        // KeepAlive that puts the errno in Console.app beats a silent lockout.
        guard chown(ThermalForgeDaemon.socketPath, 0, adminGID) == 0 else {
            let err = errno
            NSLog("ThermalForge daemon: chown of the socket to root:%u failed: errno %d", adminGID, err)
            close(fd)
            throw ThermalForgeError.writeFailed("chown() failed: errno \(err)")
        }
        guard chmod(ThermalForgeDaemon.socketPath, 0o660) == 0 else {
            let err = errno
            NSLog("ThermalForge daemon: chmod(0660) on the socket failed: errno %d", err)
            close(fd)
            throw ThermalForgeError.writeFailed("chmod() failed: errno \(err)")
        }

        guard listen(fd, 16) == 0 else {   // backlog holds queued connects while at the 8-handler cap
            close(fd)
            throw ThermalForgeError.writeFailed("listen() failed")
        }
    }

    /// Run the server loop (blocks forever)
    public func run() {
        NSLog("ThermalForge daemon: listening on %@", ThermalForgeDaemon.socketPath)

        // Watch for sleep/wake to re-apply fan settings
        registerWakeNotification()

        // Heartbeat watchdog: if app set fans to manual but hasn't checked in
        // for 15 seconds, reset to auto. Prevents fans stuck after app crash.
        startHeartbeatWatchdog()

        // Thermal safety floor: overrides a below-max hold toward max when a critical
        // sensor crosses the threshold, unkillable from user space. Defense in depth —
        // the client monitor is primary; this is the backstop that survives the app.
        startThermalFloor()

        // Accept connections concurrently (bounded) so one hung connection can't stall
        // others, and — the security fix — a slow-reading client can no longer hold
        // smcLock during the response write (processFrame takes it only around process()).
        let server = ConnectionServer(listenFD: socketFD) { [self] body in processFrame(body) }
        server.start()
        connectionServer = server

        // Main thread runs the RunLoop for wake notifications
        RunLoop.main.run()
    }

    // MARK: - Heartbeat Watchdog

    private func startHeartbeatWatchdog() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: 5)

                stateLock.lock()
                let current = hold
                stateLock.unlock()

                // ONLY a supervised hold is reverted — that's the app's crash
                // protection: the app set fans manually and stopped checking in,
                // so hand control back to macOS. An unsupervised CLI hold is
                // never touched here (the user asked for it; it persists until
                // CLI `auto` or the menu bar Default clears it). This is the
                // v0.1.5 fix: the app's heartbeat can no longer drag a CLI hold
                // into the supervised branch.
                guard case .supervised(_, let lastBeat) = current,
                      Date().timeIntervalSince(lastBeat) > 15 else { continue }

                // If the thermal floor is holding fans at max (overheating), do NOT
                // resetAuto — dropping fans while hot is the unsafe move. The app is
                // gone, so clear the dead hold (it must not be restored on cooldown);
                // fans stay at max, and the floor's cooldown path resets to auto once
                // it's safe. Crash protection preserved, its auto-reset deferred.
                stateLock.lock()
                let suspended = safetySuspended
                stateLock.unlock()
                if suspended {
                    stateLock.lock()
                    if case .supervised(_, let beat) = hold, beat == lastBeat { hold = .none }
                    stateLock.unlock()
                    NSLog("ThermalForge daemon: supervised hold timed out during thermal suspension — cleared; fans stay at max until cooldown")
                    continue
                }

                // Only the revert path allocates anything autoreleasable (NSLog +
                // error interpolation), and it never returns from this loop, so pool
                // it. The sleep/guard/continue stay outside — a steady tick allocates
                // nothing autoreleasable (Date is a value type).
                autoreleasepool {
                    NSLog("ThermalForge daemon: heartbeat timeout — resetting fans to auto")
                    smcLock.lock()
                    let resetSucceeded: Bool
                    do {
                        try fanControl.resetAuto()
                        resetSucceeded = true
                    } catch {
                        NSLog("ThermalForge daemon: watchdog reset failed: %@, will retry", "\(error)")
                        resetSucceeded = false
                    }
                    smcLock.unlock()

                    // Clear only if the reset worked AND the same supervised hold is
                    // still current — a new command may have arrived meanwhile.
                    if resetSucceeded {
                        stateLock.lock()
                        if case .supervised(_, let beat) = hold, beat == lastBeat { hold = .none }
                        stateLock.unlock()
                    }
                }
            }
        }
    }

    // MARK: - Phase 3 Invariants (rate limit, clamp, thermal floor)

    /// Consume a rate-limiter token for an SMC-writing verb. `auto`/reset never calls
    /// this — reset must never be denied.
    private func allowWrite() -> Bool {
        rateLock.lock(); defer { rateLock.unlock() }
        return rateLimiter.allow(now: Date())
    }

    /// True while the thermal floor is overriding fans to max.
    private func isSuspended() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return safetySuspended
    }

    /// Clamp a requested RPM to the fan's cached [min, max]. Returns the value to apply
    /// and an advisory note if it was clamped (the command still succeeds).
    private func clampRPM(_ rpm: Float, fan: Int) -> (value: Float, note: String?) {
        guard fan >= 0, fan < fanLimits.count else { return (rpm, nil) }
        let limit = fanLimits[fan]
        if limit.max > 0 && rpm > limit.max {
            return (limit.max, "clamped \(Int(rpm)) → \(Int(limit.max)) RPM (max)")
        }
        if limit.min > 0 && rpm < limit.min {
            return (limit.min, "clamped \(Int(rpm)) → \(Int(limit.min)) RPM (min)")
        }
        return (rpm, nil)
    }

    /// Apply a held command STRING directly to the SMC — no hold bookkeeping, so it
    /// never touches lastBeat. Shared by wake re-apply and the thermal-floor restore.
    /// Caller holds smcLock.
    private func applyCommandString(_ command: String) throws {
        let parts = command.split(separator: " ")
        switch parts.first.map(String.init) {
        case "max":
            try fanControl.setMax()
        case "set":
            if let rpm = parts.dropFirst().first.flatMap({ Float($0) }) {
                try fanControl.setAllFans(rpm: rpm)
            }
        case "setfan":
            let args = Array(parts.dropFirst())
            if args.count >= 2, let index = Int(args[0]), let rpm = Float(args[1]) {
                try fanControl.setSpeed(fan: index, rpm: rpm)
            }
        default:
            break
        }
    }

    // MARK: - Thermal Safety Floor

    /// 1s cadence: the client monitor at 100ms is primary; this is a backstop, and
    /// thermal mass doesn't move meaningfully in a second.
    private static let thermalCadence: TimeInterval = 1.0

    private func startThermalFloor() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: Self.thermalCadence)
                autoreleasepool { thermalTick() }
            }
        }
    }

    /// Peak CPU/GPU temperature. Production path reads each safety key under smcLock
    /// and RELEASES between keys: the read serializes with client writes (no torn SMC
    /// access — the defect this fixes) but never holds the lock longer than a single
    /// ~0.3ms read, so a full ~10ms sweep can't head-of-line-block a fan command.
    /// Sampling temps interleaved with writes is safe — a write changes fan speed, not
    /// the sensors, and a threshold check doesn't need an instantaneous snapshot.
    private func currentSafetyTemp() -> Float? {
        if let injected = injectedSampler { return injected() }
        var peak: Float = 0
        for key in FanControl.safetyTempKeys {
            smcLock.lock()
            let t = fanControl.readTemp(key)
            smcLock.unlock()
            if let t { peak = max(peak, t) }
        }
        return peak > 0 ? peak : nil
    }

    private func thermalTick() {
        // Read hold/suspension FIRST, and skip the SMC sweep entirely when there is no
        // hold and we aren't already overriding. Rationale (we will be asked): the floor
        // protects a HOLD. No hold means fans are on Apple's auto curve — macOS is
        // managing thermals and there is nothing for the floor to override, so a reading
        // it could not act on is not safety. The floor exists for one case: ThermalForge
        // has pinned fans below what the machine needs and something has gone wrong. The
        // client monitor at 100ms is the primary governor with its own override; this is
        // the backstop that survives the app's death. So an idle daemon does zero SMC
        // work per tick — only a live below-max hold (or an active suspension) samples.
        stateLock.lock()
        let suspended = safetySuspended
        let heldCommand = hold.command
        stateLock.unlock()

        guard suspended || heldCommand != nil else { return }

        guard let temp = currentSafetyTemp() else { return }

        switch thermalFloor.evaluate(temp: temp, holdCommand: heldCommand, suspended: suspended) {
        case .none:
            return

        case .engage:
            // Override the below-max hold to max. Direct SMC write — NEVER recordHold,
            // so the user's command + lastBeat are preserved for restore.
            smcLock.lock()
            let ok = (try? fanControl.setMax()) != nil
            smcLock.unlock()
            guard ok else { return }
            stateLock.lock(); safetySuspended = true; stateLock.unlock()
            NSLog("ThermalForge daemon: thermal floor engaged at %.1f°C — fans held at max (was %@)",
                  temp, heldCommand ?? "none")

        case .restore:
            // Re-read the hold at restore time — the watchdog may have cleared a dead
            // app's hold during the suspension, in which case go to auto instead.
            stateLock.lock()
            let restoreCommand = hold.command
            stateLock.unlock()
            smcLock.lock()
            if let cmd = restoreCommand {
                try? applyCommandString(cmd)
            } else {
                try? fanControl.resetAuto()
            }
            smcLock.unlock()
            stateLock.lock(); safetySuspended = false; stateLock.unlock()
            NSLog("ThermalForge daemon: thermal floor cleared at %.1f°C — %@",
                  temp, restoreCommand.map { "restored \($0)" } ?? "reset to auto")
        }
    }

    // MARK: - Sleep/Wake

    /// IOKit root port for power notifications
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private func registerWakeNotification() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon, &notifyPort, { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let server = Unmanaged<DaemonServer>.fromOpaque(refcon).takeUnretainedValue()

                // IOKit message constants (macros unavailable in Swift)
                let kSystemHasPoweredOn: UInt32 = 0xe0000300
                let kSystemWillSleep: UInt32 = 0xe0000280
                let kCanSystemSleep: UInt32 = 0xe0000270

                switch messageType {
                case kSystemHasPoweredOn:
                    server.handleWake()
                case kSystemWillSleep, kCanSystemSleep:
                    IOAllowPowerChange(server.rootPort, numericCast(Int(bitPattern: messageArgument)))
                default:
                    break
                }
            }, &notifier
        )

        guard rootPort != 0, let notifyPort = notifyPort else {
            NSLog("ThermalForge daemon: failed to register for power notifications")
            return
        }

        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        NSLog("ThermalForge daemon: registered for wake notifications")
    }

    private func handleWake() {
        stateLock.lock()
        let heldCommand = hold.command
        stateLock.unlock()
        guard let command = heldCommand else {
            NSLog("ThermalForge daemon: woke — no profile to re-apply")
            return
        }

        NSLog("ThermalForge daemon: woke — re-applying: %@", command)

        // Delay slightly — SMC needs a moment after wake
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [self] in
            smcLock.lock()
            defer { smcLock.unlock() }
            do {
                try applyCommandString(command)
                NSLog("ThermalForge daemon: re-applied after wake")
            } catch {
                NSLog("ThermalForge daemon: wake re-apply failed: %@", "\(error)")
            }
        }
    }

    // MARK: - Request Processing

    /// Decode a request body → reply: the framing/version/log wrapper around the
    /// atomic process(). smcLock is taken ONLY for the process() call — never around
    /// the I/O, so a slow-reading client can no longer hold it during the write.
    /// Returns a `ConnectionReply` so a `.restart` can defer shutdown until its
    /// acknowledgement is actually written (see `scheduleRestartShutdown`).
    private func processFrame(_ body: Data) -> ConnectionReply {
        guard let request = try? DaemonProtocol.decode(DaemonRequest.self, from: body) else {
            // Undecodable = unknown verb or a shape from a newer client.
            return ConnectionReply(.unsupported(daemonVersion: ThermalForgeVersion.current))
        }
        // A newer protocol than we speak → tell the client our build so it can react.
        guard request.v <= DaemonProtocol.version else {
            return ConnectionReply(.unsupported(daemonVersion: ThermalForgeVersion.current))
        }
        smcLock.lock()
        let response = process(request)
        smcLock.unlock()
        // Verb + outcome only — never raw client bytes.
        NSLog("ThermalForge daemon: verb=%@ outcome=%@", request.verb.rawValue,
              response.ok ? "ok" : (response.error?.rawValue ?? "error"))

        // `.restart` replies first; the actual resetAuto + exit is deferred to the
        // write completion (or the 5s fallback) so the client observes `ok` before
        // the socket dies.
        if request.verb == .restart, response.ok {
            return ConnectionReply(response, onWriteComplete: scheduleRestartShutdown())
        }
        return ConnectionReply(response)
    }

    // MARK: - Restart Shutdown

    /// Arm the `.restart` shutdown: reset the fans to Apple auto, then exit so
    /// launchd (KeepAlive) respawns the freshly-installed helper from the bundle.
    ///
    /// State-loss semantics (deliberate, from the plan): exiting leaves the
    /// hardware in Apple's auto mode — the safe default — because `resetAuto()` runs
    /// before `exit(0)`. The app re-establishes its hold after the version recovers
    /// (it forces one monitor write). A CLI's unsupervised hold ends at the restart
    /// (a CLI cannot supervise across a process boundary); because we reset to Apple
    /// auto there is no unattended window of stuck manual RPM, and the thermal floor
    /// keys off "no hold", which now genuinely means Apple is managing thermals — so
    /// it correctly skips evaluation.
    ///
    /// The returned closure runs after the response write settles (success OR a
    /// write error from a disconnected client). A 5s timer is the fallback if that
    /// completion never fires (client vanished before the write could start); the
    /// one-shot guard makes either path win exactly once.
    private func scheduleRestartShutdown() -> () -> Void {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.performRestartShutdown()
        }
        return { [weak self] in self?.performRestartShutdown() }
    }

    private func performRestartShutdown() {
        restartLock.lock()
        if restartScheduled {
            restartLock.unlock()
            return
        }
        restartScheduled = true
        restartLock.unlock()

        smcLock.lock()
        do {
            try fanControl.resetAuto()
        } catch {
            NSLog("ThermalForge daemon: resetAuto on restart failed: %@", "\(error)")
        }
        smcLock.unlock()

        stateLock.lock(); hold = .none; safetySuspended = false; stateLock.unlock()
        NSLog("ThermalForge daemon: restart requested — fans reset to Apple auto, exiting for launchd respawn")
        exit(0)
    }

    /// The full request dispatch — MOVED VERBATIM from the pre-Phase-4 serial handler.
    /// The CALLER holds smcLock for the whole call, so every check-then-act
    /// (blockedByCLIHold, rate limit, clamp, recordHold + SMC write) stays atomic exactly
    /// as before; Phase 4 concurrency lives only in the I/O around this, never inside it.
    /// Same-class concurrent writers resolve by last-write-wins (recordHold overwrites) —
    /// the one authority rule is cross-class (CLI outranks app via blockedByCLIHold);
    /// equal-authority ties are arbitrary-but-consistent by design, not by lock order.
    private func process(_ request: DaemonRequest) -> DaemonResponse {
        let response: DaemonResponse
        do {
            let oneshot = request.oneshot

            // Record a hold: unsupervised (CLI oneshot — never watchdog-reverted) or
            // supervised (app — reverted if it stops checking in). Overwrites whatever
            // was held, so an explicit app command cleanly takes over a CLI hold with
            // no orphan left behind. The command STRING is kept verbatim so wake
            // re-apply (handleWake) and the `state` snapshot are unchanged.
            func recordHold(_ heldCommand: String) {
                stateLock.lock()
                hold = oneshot
                    ? .unsupervised(command: heldCommand)
                    : .supervised(command: heldCommand, lastBeat: Date())
                stateLock.unlock()
            }

            // A supervised (app) command must NOT silently overwrite an unsupervised
            // CLI hold — the CLI hold wins and the app is told to yield via the error,
            // instead of clobbering it in the ~100ms before its next state poll.
            // `oneshot` commands and `auto` are never blocked, so explicit app takeover
            // (which sends `auto` first, clearing the hold) still works.
            func blockedByCLIHold() -> Bool {
                guard !oneshot else { return false }
                stateLock.lock(); defer { stateLock.unlock() }
                if case .unsupervised = hold { return true }
                return false
            }

            // Flood cap for SMC-writing verbs. `auto`/reset is exempt — a reset must
            // never be denied. Checked after usage validation (malformed requests
            // don't burn tokens), before the write.
            let rateLimited = DaemonResponse.failure(.rateLimited, "too many fan commands; try again shortly")

            switch request.verb {
            case .max:
                if !allowWrite() { response = rateLimited; break }
                if blockedByCLIHold() { response = .failure(.heldByCLI, "held by cli"); break }
                // Skip the SMC write while the thermal floor holds fans at max — record
                // the new hold to restore on cooldown, but don't drop fans while hot.
                if !isSuspended() { try fanControl.setMax() }
                recordHold("max")
                response = .ok()
            case .auto:
                // Exempt from the rate cap. Also the "hand back to Apple's auto curve"
                // path, so it clears any thermal suspension — Apple's auto handles heat.
                try fanControl.resetAuto()
                stateLock.lock(); hold = .none; safetySuspended = false; stateLock.unlock()
                response = .ok()
            case .set:
                guard let rpm = request.rpm else {
                    response = .failure(.usage, "usage: set <rpm>")
                    break
                }
                if !allowWrite() { response = rateLimited; break }
                if blockedByCLIHold() { response = .failure(.heldByCLI, "held by cli"); break }
                let (clamped, note) = clampRPM(Float(rpm), fan: 0)
                if !isSuspended() { try fanControl.setAllFans(rpm: clamped) }
                recordHold("set \(Int(clamped))")
                response = .ok(note: note, appliedRPM: Int(clamped))
            case .setfan:
                guard let index = request.fan, let rpm = request.rpm else {
                    response = .failure(.usage, "usage: setfan <index> <rpm>")
                    break
                }
                if !allowWrite() { response = rateLimited; break }
                if blockedByCLIHold() { response = .failure(.heldByCLI, "held by cli"); break }
                let (clamped, note) = clampRPM(Float(rpm), fan: index)
                if !isSuspended() { try fanControl.setSpeed(fan: index, rpm: clamped) }
                recordHold("setfan \(index) \(Int(clamped))")
                response = .ok(note: note, appliedRPM: Int(clamped))
            case .status:
                // Same snake_case shape as the standalone CLI `status`, carried as an
                // opaque payload string (no consumer decodes it today).
                let status = try fanControl.status()
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(status)
                response = .statusResponse(String(data: data, encoding: .utf8) ?? "{}")
            case .state:
                // Current hold + owner (+ whether the thermal floor is overriding it),
                // so the app can reflect a CLI hold rather than fight or wipe it.
                stateLock.lock()
                let snap = hold.snapshot(safetySuspended: safetySuspended)
                stateLock.unlock()
                response = .stateResponse(snap)
            case .heartbeat:
                // Refreshes a SUPERVISED hold's liveness only. On an unsupervised CLI
                // hold this is deliberately a no-op — the app checking in must NOT
                // convert a CLI hold into a supervised one (the v0.1.5 bug).
                stateLock.lock()
                if case .supervised(let c, _) = hold {
                    hold = .supervised(command: c, lastBeat: Date())
                }
                stateLock.unlock()
                response = .ok()
            case .version:
                // Reports the build this daemon process is running, so a CLI from a
                // newer install can detect it's talking to a stale daemon.
                response = .versionResponse(ThermalForgeVersion.current)
            case .restart:
                // The app's self-heal verb when it detects a version mismatch after
                // an update: acknowledge now, and processFrame defers resetAuto + exit
                // until this acknowledgement is written. No SMC work happens here —
                // the shutdown path owns that, so it can't race the reply.
                response = .ok()
            }
        } catch {
            response = .failure(.internal, "\(error)")
        }

        return response
    }

    deinit {
        close(socketFD)
        unlink(ThermalForgeDaemon.socketPath)
    }
}

// MARK: - Helpers

/// Copy a path string into sockaddr_un.sun_path
private func setPath(_ addr: inout sockaddr_un, _ path: String) {
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            _ = strlcpy(dest, path, 104)
        }
    }
}

/// Connect `fd` to `addr` bounded by `timeout` seconds, so a wedged daemon (accept
/// loop stalled, listen backlog full) can never block the caller forever. Both
/// `DaemonClient.sendRaw` (throws on false) and `ThermalForgeDaemon.isRunning`
/// (returns the Bool) go through here, so the two connect paths can't diverge.
///
/// Non-blocking connect, then `poll()` for completion. `poll()` is retried on EINTR
/// with the REMAINING budget — a signal must not turn a healthy daemon into a
/// spurious "not running". On success the socket is restored to blocking mode so
/// any SO_RCVTIMEO/SO_SNDTIMEO the caller set still governs the following read/write.
private func connectWithTimeout(_ fd: Int32, _ addr: inout sockaddr_un, timeout: TimeInterval) -> Bool {
    let origFlags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, origFlags | O_NONBLOCK)

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    var connected: Bool
    if rc == 0 {
        connected = true
    } else if errno == EINPROGRESS {
        connected = false
        let deadline = DispatchTime.now() + timeout
        while true {
            let now = DispatchTime.now()
            if now >= deadline { break }   // budget exhausted → not connected
            let remainingMs = Int32((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000)

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let por = poll(&pfd, 1, remainingMs)
            if por > 0 {
                // Woke on writability: connect finished — success iff SO_ERROR == 0.
                var soErr: Int32 = 0
                var soLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
                connected = (soErr == 0)
                break
            } else if por == 0 {
                break                       // timed out → not connected
            } else if errno == EINTR {
                continue                    // interrupted — recompute remaining budget, retry
            } else {
                break                       // real poll error → not connected
            }
        }
    } else {
        connected = false                   // ECONNREFUSED, EAGAIN (backlog full), …
    }

    if connected { _ = fcntl(fd, F_SETFL, origFlags) }   // restore blocking for read/write
    return connected
}
