//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    /// Lifecycle of the embedded privileged helper's SMAppService registration.
    /// Drives the registration banner; `ready` is the ordering gate that lets
    /// daemon adoption and the heartbeat start.
    enum HelperRegistrationStatus: Equatable {
        case checking
        case registering
        case requiresApproval
        case failed(String)
        case ready
    }

    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .silent
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    /// Reflects the current SMAppService login-item status so the menu toggle shows the
    /// right state. Initialized from that status as the property's DEFAULT (not reassigned
    /// in init), so `didSet` does NOT fire on launch — reading the state must never
    /// re-register. `updateLoginItem()` runs only when the user flips the toggle (the
    /// SwiftUI binding writes this), never on every launch.
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { updateLoginItem() }
    }
    /// The running helper's version when it differs from this app's build, else
    /// nil. Non-nil drives the "update needed" banner and menu bar badge. The
    /// app self-heals on mismatch (restart the helper → poll → re-register if
    /// needed); this stays non-nil only while recovery is running or after it
    /// has exhausted its automatic attempts.
    @Published var daemonVersionMismatch: String?
    /// True while the automatic version-mismatch recovery is running; the update
    /// banner shows progress and hides the manual retry until it settles.
    @Published private(set) var daemonRecoveryInProgress: Bool = false
    /// SMAppService registration state for the embedded helper. Starts `checking`
    /// and only reaches `ready` after the system has approved the daemon.
    @Published private(set) var helperRegistration: HelperRegistrationStatus = .checking
    /// A hold set from the CLI (`thermalforge max`) that the app is
    /// reflecting rather than fighting. Non-nil suspends the app's automatic
    /// profile control and drives the "held from Terminal" banner; the user
    /// takes back over by picking a profile or pressing Default.
    @Published var externalHold: DaemonHoldState?
    /// True when the daemon has stopped answering (two consecutive missed
    /// heartbeats). Drives the "fan control unavailable" banner + Restart button:
    /// without the daemon the app can't control fans at all, so this must be
    /// visible, not just logged. Cleared the moment a heartbeat succeeds.
    @Published var daemonUnreachable: Bool = false
    /// A GitHub release newer than this installed build, else nil. Non-nil drives
    /// the "Update available" banner. Set from a once-daily check and from persisted
    /// state on launch (so it shows without waiting for a network round-trip); a
    /// dismissed version is suppressed until a newer one ships.
    @Published var availableUpdate: AvailableUpdate?

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: DispatchSourceTimer?
    /// Consecutive failed heartbeats, for debouncing `daemonUnreachable`.
    private var heartbeatFailures = 0
    /// Last time the heartbeat's hold-lost reconciliation fired a re-engage.
    /// Rate-limits it to one per `lossReengageInterval` so a re-engage whose own
    /// write keeps failing can't thrash the monitor on every 5s beat.
    private var lastLossReengage = Date.distantPast
    /// Last time the unreachable-with-status-enabled path ran a verified
    /// re-register cycle (stale-launch-constraint healing after an update).
    private var lastDownRegistrationCycle = Date.distantPast
    /// Minimum spacing between hold-lost re-engages (see `lastLossReengage`).
    private static let lossReengageInterval: TimeInterval = 30

    /// True when the monitor believes the app is actively holding a fan setting —
    /// an `.active` curve profile or a `.safetyOverride`. `.idle` means it isn't,
    /// so there is no hold to have been lost.
    private static func isActivelyControlling(_ state: MonitorState) -> Bool {
        switch state {
        case .active, .safetyOverride: return true
        case .idle: return false
        }
    }

    /// Serial queue for the SMAppService registration calls, which can block on
    /// the system admin-authorization dialog. Never the main thread.
    private let registrationQueue = DispatchQueue(label: "com.thermalforge.registration", qos: .userInitiated)
    /// Polls SMAppService status while a registration waits on user approval.
    private var registrationPollTimer: DispatchSourceTimer?
    /// Set once adopt + heartbeat have been released through the registration
    /// gate; keeps a later re-registration from adopting/running them twice.
    private var adoptionStarted = false
    /// True once automatic version recovery has exhausted its attempts, so the
    /// heartbeat doesn't retry it on every 5s tick. Cleared by the banner retry.
    private var daemonRecoveryExhausted = false

    /// The embedded launch daemon's SMAppService handle. `nonisolated` so the
    /// registration queue can read status / register off the main actor; it
    /// touches no instance state.
    nonisolated private var daemonService: SMAppService {
        SMAppService.daemon(plistName: DaemonBundlePlist.filename)
    }

    /// Runs the 5s heartbeat/version/state polls OFF the main thread so a slow
    /// or hung daemon can never stall the UI run loop (the v0.1.7 freeze).
    private let heartbeatQueue = DispatchQueue(label: "com.thermalforge.heartbeat", qos: .utility)
    /// Off-main, serial, coalescing pump for all daemon-bound fan writes (launch
    /// adopt + monitor ramp commands). It owns its own queue, so this @MainActor
    /// class never runs socket I/O on the main actor — off-main by construction,
    /// not by relying on lax isolation. The injected executor closure runs on the
    /// pump's queue; a CLI-hold rejection is reflected back onto externalHold on the
    /// main actor.
    private lazy var commandPump: FanCommandPump = {
        let executor = self.executor   // capture the Sendable executor value (off-main use)
        return FanCommandPump { [weak self] command in
            do {
                try executor.execute(command)
                return true
            } catch {
                // Failure is NEVER silent. If a CLI hold owns the fans, this is
                // expected arbitration — reflect it on the main actor so the monitor
                // stops trying and the banner appears immediately (don't wait up to
                // 5s for the poll). Otherwise it's a real failure — log it.
                if let state = try? DaemonClient().readState(), state.isCLIHold {
                    TFLogger.shared.info("Fan command yielded to CLI hold: \(command)")
                    Task { @MainActor in self?.externalHold = state }
                } else {
                    TFLogger.shared.error("Fan command failed: \(command) — \(error)")
                }
                return false
            }
        }
    }()

    init() {
        // launchAtLogin is initialized from SMAppService status as its property default
        // (above), NOT reassigned here — reassigning would fire didSet and re-register on
        // every launch. Reflecting state is a read; only a user toggle should register.

        // Show a previously-found update immediately, before any network call.
        availableUpdate = Self.storedAvailableUpdate()

        // Registration (or re-adoption) of the embedded privileged helper comes
        // FIRST. register() can block on the system admin-authorization dialog,
        // so it runs on registrationQueue and only calls back on `.ready`; adopt
        // and heartbeat are gated on that (the ordering gate below). Fan/temp
        // reads are unprivileged and must keep working regardless, so start
        // monitoring unconditionally and never wait on registration for it.
        beginHelperRegistration()

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        // adoptDaemonStateOnLaunch() is now released from finishHelperRegistration()
        // (on `.ready`), and startHeartbeat() from adopt's completion — so neither
        // can run before the helper is registered and approved. The original
        // synchronous adopt gave this ordering for free; the async version must
        // restore it explicitly.
    }

    // MARK: - Helper registration (SMAppService)

    /// Start (or restart) the registration state machine. Safe to call again for
    /// runtime revocation: it re-reads status and re-enters the appropriate
    /// branch. Never blocks the main thread — `register()` may wait on the system
    /// auth prompt, so it runs on `registrationQueue`.
    func beginHelperRegistration() {
        registrationPollTimer?.cancel()
        registrationPollTimer = nil
        helperRegistration = .checking
        registrationQueue.async { [weak self] in
            self?.performRegistrationFlow()
        }
    }

    /// Retry from the registration banner after a failure/denial.
    func retryHelperRegistration() {
        beginHelperRegistration()
    }

    /// Runs OFF the main thread. Reads the helper's SMAppService status and
    /// registers once when it isn't registered yet; every branch hops back to
    /// the main actor to update published state.
    nonisolated private func performRegistrationFlow() {
        let service = SMAppService.daemon(plistName: DaemonBundlePlist.filename)
        switch service.status {
        case .enabled:
            Task { @MainActor [weak self] in self?.finishHelperRegistration() }
        case .requiresApproval:
            // A prior registration is still pending the user's approval — don't
            // re-register; surface the banner and poll.
            Task { @MainActor [weak self] in self?.enterHelperApproval() }
        default:
            // .notRegistered → register for the first time. `.notFound` (macOS
            // 15+) or any future status means the helper isn't usable yet, so
            // the same register attempt (and its banner on failure) applies.
            Task { @MainActor [weak self] in self?.helperRegistration = .registering }
            do {
                try service.register()
                switch service.status {
                case .enabled:
                    Task { @MainActor [weak self] in self?.finishHelperRegistration() }
                case .requiresApproval:
                    Task { @MainActor [weak self] in self?.enterHelperApproval() }
                default:
                    Task { @MainActor [weak self] in
                        self?.helperRegistration = .failed("The helper was registered but the system hasn't enabled it yet. Approve it in System Settings, then retry.")
                    }
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.helperRegistration = .failed(message)
                }
            }
        }
    }

    @MainActor
    private func enterHelperApproval() {
        helperRegistration = .requiresApproval
        startRegistrationPolling()
    }

    @MainActor
    private func finishHelperRegistration() {
        registrationPollTimer?.cancel()
        registrationPollTimer = nil
        helperRegistration = .ready
        proceedIfRegistrationReady()
    }

    /// The ordering gate: adopt the daemon's launch state (and, via its
    /// completion, start the heartbeat) only once, and only after registration
    /// is `.ready`. A later re-registration after revocation leaves the already
    /// running heartbeat in place — it recovers on its own once the daemon is
    /// back — so adoption must not run twice.
    @MainActor
    private func proceedIfRegistrationReady() {
        guard !adoptionStarted, helperRegistration == .ready else { return }
        adoptionStarted = true
        adoptDaemonStateOnLaunch()
    }

    /// Poll SMAppService while approval is pending; the status flips to
    /// `.enabled` once the user approves in System Settings. Two seconds is
    /// responsive without meaningfully touching the system each tick.
    @MainActor
    private func startRegistrationPolling() {
        registrationPollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: registrationQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let status = SMAppService.daemon(plistName: DaemonBundlePlist.filename).status
            switch status {
            case .enabled:
                Task { @MainActor [weak self] in self?.finishHelperRegistration() }
            case .requiresApproval:
                break   // still waiting on the user — keep polling
            default:
                // Approval was denied / registration was removed while waiting.
                Task { @MainActor [weak self] in
                    self?.registrationPollingLost()
                }
            }
        }
        timer.resume()
        registrationPollTimer = timer
    }

    @MainActor
    private func registrationPollingLost() {
        registrationPollTimer?.cancel()
        registrationPollTimer = nil
        helperRegistration = .failed("Background helper approval wasn't granted. Approve ThermalForge in System Settings, then retry.")
    }

    /// Open System Settings to the Login Items & Extensions pane, where the user
    /// approves the pending helper. The polling above notices the approval.
    @MainActor
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Sync to whatever the daemon is actually holding at launch instead of
    /// blindly resetting (which destroyed a deliberate CLI hold and the daemon's
    /// record of it). A CLI hold is reflected and left alone; a stale supervised
    /// hold left by a crashed prior app instance is cleared here — that's the
    /// crash recovery the old reset provided, without the collateral damage.
    private func adoptDaemonStateOnLaunch() {
        let executor = self.executor
        // Read the daemon's launch state OFF the main thread so an unresponsive
        // daemon can't stall app launch — the socket read is bounded by the sendRaw
        // timeout. runAtLaunch puts this on the pump's serial queue AHEAD of any
        // ramp write, so a stale-hold reset here can never be reordered behind a
        // monitor command. During the brief pre-adopt window the monitor may still
        // issue a command; shipped arbitration rejects an app write over a CLI hold
        // and the pump latches it, so no fan state is corrupted.
        commandPump.runAtLaunch { [weak self] in
            let state = try? DaemonClient().readState()

            // Same four-way decision as before, just resolved off-main; any reset
            // runs here and only the resulting externalHold is applied on main.
            let adopted: DaemonHoldState?
            if let state, state.isCLIHold {
                // Deliberate CLI hold — reflect it, don't touch it.
                adopted = state
                TFLogger.shared.info("App launched — reflecting CLI hold: \(state.command ?? "?")")
            } else if let state, !state.isEmpty {
                // Leftover supervised hold from a crashed prior instance — this is
                // the live app now, so take over by clearing it (the crash
                // recovery the old blind reset provided).
                adopted = nil
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — cleared stale app hold")
            } else if state != nil {
                adopted = nil
                TFLogger.shared.info("App launched — no active hold")
            } else {
                // State unreadable — a pre-0.1.7 daemon with no `state` verb
                // (upgrade window) or unreachable. DELIBERATE fallback to the old
                // conservative reset: without arbitration we can't tell a CLI hold
                // from a crashed prior instance's stale hold, and leaving fans
                // possibly stuck is worse than clearing a possible CLI hold.
                // Bounded to the pre-0.1.7 daemon window, where the version-
                // mismatch banner already tells the user to re-sync.
                adopted = nil
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — daemon state unreadable; reset to auto (degraded)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.externalHold = adopted
                // Restore the user's last chosen profile, but NEVER over a reflected CLI
                // hold — that hold is the most recent explicit intent and wins. With no
                // hold (including the crash-recovery branch above that just cleared a
                // stale app hold), apply the saved choice, so a crash while a profile
                // was running comes back to that profile. Deferred to here so the hold
                // state is known before any fan command is issued (no pre-adopt commands
                // in the window).
                if adopted == nil {
                    let restored = self.restoredProfile()
                    self.activeProfile = restored
                    self.monitor?.switchProfile(restored)
                }
                // Ordering gate: only now that adopt has applied the launch state
                // do we start the heartbeat. This makes adopt's externalHold write
                // strictly precede the first poll's write, so a late adopt (e.g. the
                // timeout path, ~4s) can't clobber a fresher heartbeat value. It
                // also means an unbounded connect() inside adopt merely delays the
                // first heartbeat (all off the main thread) — it never stalls launch.
                self.startHeartbeat()
            }
        }
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            // Runs OFF the main thread. Each socket round-trip is bounded by the
            // request timeout, so a hung daemon can no longer stall the UI.

            // During a version-mismatch recovery the helper is deliberately being
            // restarted / re-registered. Skip this tick entirely so the two-miss
            // `daemonUnreachable` debounce can't flap over an intended restart,
            // and so the recovery owns the polling window. Snapshot `active` and
            // `generation` in ONE lock acquisition so a recovery beginning between
            // two reads can't slip a post-begin generation past the gate.
            let window = daemonRecoveryWindow.snapshot
            if window.active { return }

            // Capture the recovery generation BEFORE the socket I/O below. A tick
            // that began before a recovery window opened can still be in flight when
            // that window starts and ends; re-checking only `isActive` in the
            // completion would miss it. If the generation moved, the result is stale.
            let recoveryGeneration = window.generation

            // Heartbeat is NOT advisory: it refreshes the supervised hold's
            // liveness and the daemon watchdog reverts after 15s of silence. One
            // immediate retry absorbs a transient blip without waiting a full 5s
            // for the next tick.
            let firstBeat = (try? client.request(DaemonRequest(verb: .heartbeat)))?.ok == true
            let hbOK = firstBeat || ((try? client.request(DaemonRequest(verb: .heartbeat)))?.ok == true)

            // Advisory: version + state. On failure/timeout DON'T assert — leave
            // the last known value untouched rather than clearing the banner on a
            // transient blip. Only a definitive read updates published state. Both
            // the `version` reply and an `unsupportedVersion` reply carry the
            // daemon's build; a reply without one is treated as an older build.
            let didReadVersion: Bool
            let versionValue: String?
            do {
                let response = try client.request(DaemonRequest(verb: .version))
                let daemonVersion = response.version ?? "an older build"
                versionValue = (daemonVersion == ThermalForgeVersion.current) ? nil : daemonVersion
                didReadVersion = true
            } catch DaemonError.incompatibleDaemon {
                // Legacy (pre-Phase-2) daemon in the upgrade window → show the
                // update-needed banner rather than leaving it stale.
                versionValue = "an older build"
                didReadVersion = true
            } catch {
                versionValue = nil
                didReadVersion = false
            }

            // Poll the daemon's hold so a CLI hold set out-of-band shows up in the
            // menu bar and suspends our monitor. Unreadable → leave externalHold
            // as-is (don't clear a reflected CLI hold on a transient failure).
            let didReadState: Bool
            let holdValue: DaemonHoldState?
            /// The daemon's raw state this beat (owner "none"/"cli"/"app"), needed
            /// beyond the CLI-hold projection to detect a lost app hold below.
            let daemonState: DaemonHoldState?
            if let hold = try? client.readState() {
                daemonState = hold
                holdValue = hold.isCLIHold ? hold : nil
                didReadState = true
            } else {
                daemonState = nil
                holdValue = nil
                didReadState = false
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // A recovery window began (or completed) while this tick's socket
                // I/O was in flight. Its reachability/version results belong to the
                // pre-recovery world — applying them could increment
                // heartbeatFailures and flip daemonUnreachable mid-recovery. Discard
                // the whole tick.
                guard daemonRecoveryWindow.currentGeneration == recoveryGeneration else { return }
                if didReadVersion { self.daemonVersionMismatch = versionValue }
                if didReadState { self.externalHold = holdValue }
                // A definitive version read that disagrees with this build is the
                // mismatch signal: start (or continue) automatic recovery. The
                // recovery is idempotent — a concurrent run and an exhausted run
                // both short-circuit — and it suppresses further heartbeat ticks
                // while it owns the restart window.
                if didReadVersion, versionValue != nil {
                    self.beginDaemonRecovery()
                }
                // Apply this tick's reachability bookkeeping ONLY if no recovery
                // owns the window and the generation hasn't moved. A mismatch tick
                // that just opened a recovery window must not ALSO count as a failed
                // heartbeat: that stale pre-recovery result would increment
                // heartbeatFailures / flip daemonUnreachable mid-recovery. Reading
                // the two fields separately is safe here — begin()/end() run only on
                // the main actor, so the window can't change under this sync block.
                guard daemonRecoveryWindow.currentGeneration == recoveryGeneration,
                      !daemonRecoveryWindow.isActive else { return }
                // Daemon reachability — debounced so a single blip doesn't flash the
                // "fan control unavailable" banner. Two consecutive missed heartbeats
                // (~10s) is a real outage; any success clears it immediately.
                if hbOK {
                    self.heartbeatFailures = 0
                    let wasUnreachable = self.daemonUnreachable
                    self.daemonUnreachable = false
                    if wasUnreachable {
                        // The helper is back after launchd respawned it (a crash or
                        // uncommanded exit — KeepAlive). Unlike the `.restart` path,
                        // a crash runs no resetAuto, so the fans may be left manual
                        // and the daemon's supervised hold died with the process.
                        // Rebuild control exactly as version recovery does.
                        self.reengageAfterHelperRecovery(reason: "respawned after crash")
                    } else if didReadState, let daemon = daemonState,
                              self.externalHold == nil,
                              Self.isActivelyControlling(self.monitorState),
                              daemon.owner != "app" {
                        // Fast-respawn window: a KeepAlive respawn can complete
                        // between two beats, before the two-miss debounce ever sets
                        // `daemonUnreachable` — so `wasUnreachable` is false and yet
                        // the new daemon holds no app hold. The heartbeat already
                        // read the daemon state, so detect the loss directly: the app
                        // believes it is controlling (monitorState active/safety) while
                        // the daemon's owner is not "app" (it holds nothing, or holds
                        // someone else's). NO CLI hold is reflected (externalHold nil),
                        // so there is nothing to yield to. Rebuild the hold.
                        // Rate-limited so a re-engage whose write keeps failing can't
                        // fire every beat; a successful write makes owner == "app"
                        // and naturally clears the condition.
                        if Date().timeIntervalSince(self.lastLossReengage) >= Self.lossReengageInterval {
                            self.lastLossReengage = Date()
                            self.reengageAfterHelperRecovery(reason: "hold lost across respawn")
                        }
                    }
                } else {
                    self.heartbeatFailures += 1
                    if self.heartbeatFailures >= 2 {
                        let becameUnreachable = !self.daemonUnreachable
                        self.daemonUnreachable = true
                        // The socket can go quiet because the helper's SMAppService
                        // registration was revoked (or is pending approval), not
                        // because of a crash. In that case a launchd kickstart can't
                        // help — re-enter the registration state machine instead.
                        if becameUnreachable { self.checkRegistrationWhileUnreachable() }
                    }
                }
            }

            // Ride the heartbeat as a cheap clock, but hit the network at most once a
            // day. Runs off-main; nothing here touches published state directly.
            self?.maybeCheckForUpdate()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Update check

    // nonisolated: read from `maybeCheckForUpdate` on the heartbeat queue. Static
    // members of a @MainActor type are otherwise MainActor-isolated (a Swift 6 error
    // to touch off-main); these are immutable constants, so isolation buys nothing.
    //
    // We persist the NEXT allowed check time, not the last one, so the gate is a plain
    // `now >= nextCheck` and both the normal and backed-off cases store `now + interval`
    // — no negative-interval arithmetic to misread as a bug later.
    nonisolated private static let updateNextCheckKey = "updateNextCheck"
    nonisolated private static let updateLatestVersionKey = "updateLatestVersion"
    nonisolated private static let updateLatestURLKey = "updateLatestURL"
    nonisolated private static let updateDismissedKey = "updateDismissedVersion"
    /// Normal cadence: next check a day out. A machine asleep/off checks on next wake.
    nonisolated private static let updateCheckInterval: TimeInterval = 24 * 60 * 60
    /// After a failed check, next check ~1h out instead of a full day.
    nonisolated private static let updateRetryInterval: TimeInterval = 60 * 60

    /// Reconstruct the last-known available update from persisted state (launch path),
    /// suppressing a version the user dismissed.
    private static func storedAvailableUpdate() -> AvailableUpdate? {
        let d = UserDefaults.standard
        guard let version = d.string(forKey: updateLatestVersionKey),
              version != d.string(forKey: updateDismissedKey) else { return nil }
        return UpdateChecker.evaluate(
            current: ThermalForgeVersion.current,
            tagName: version,
            url: d.string(forKey: updateLatestURLKey) ?? UpdateChecker.releasesPageURL
        )
    }

    /// Fire a check if a day has elapsed. `nonisolated` so it runs on the heartbeat
    /// queue; only UserDefaults (thread-safe) is touched here, and the result is
    /// applied back on the main actor.
    nonisolated private func maybeCheckForUpdate() {
        let defaults = UserDefaults.standard
        let nextCheck = (defaults.object(forKey: Self.updateNextCheckKey) as? Date) ?? .distantPast
        guard Date() >= nextCheck else { return }
        // Claim the window up front so the 5s heartbeat can't refire the fetch.
        defaults.set(Date().addingTimeInterval(Self.updateCheckInterval), forKey: Self.updateNextCheckKey)

        Task { [weak self] in
            let result = await UpdateChecker.check()
            if case .failed = result {
                // Transient failure — pull the next check back to ~1h out, not a day.
                defaults.set(Date().addingTimeInterval(Self.updateRetryInterval), forKey: Self.updateNextCheckKey)
            }
            await self?.applyUpdateCheck(result)
        }
    }

    /// Apply a completed check. `.failed` is silent (prior state untouched). Only a
    /// definitive result changes what the user sees.
    func applyUpdateCheck(_ result: UpdateCheckResult) {
        let d = UserDefaults.standard
        switch result {
        case .failed:
            return
        case .upToDate:
            d.removeObject(forKey: Self.updateLatestVersionKey)
            d.removeObject(forKey: Self.updateLatestURLKey)
            availableUpdate = nil
        case .update(let update):
            d.set(update.version, forKey: Self.updateLatestVersionKey)
            d.set(update.url, forKey: Self.updateLatestURLKey)
            // Honor a dismissal until a still-newer version arrives.
            if update.version != d.string(forKey: Self.updateDismissedKey) {
                availableUpdate = update
            }
        }
    }

    /// "Later" — hide the banner for this version; it returns when a newer one ships.
    func dismissUpdate() {
        if let version = availableUpdate?.version {
            UserDefaults.standard.set(version, forKey: Self.updateDismissedKey)
        }
        availableUpdate = nil
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                self?.latestStatus = status
                self?.activeProfile = profile
                self?.monitorState = state
                // Max of only the displayed sensors
                // Peak across all CPU and GPU sensors for menu bar display
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                self?.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't fight a CLI hold — the user set it deliberately. Decide on
                // the main actor where externalHold lives; the monitor resumes
                // control when they pick a profile or press Default.
                guard self.externalHold == nil else { return }
                // Hand off to the coalescing pump; the blocking socket write happens
                // OFF the main thread. During a ramp these fire up to ~10x/sec;
                // previously each ran a blocking round-trip on the main actor and
                // starved the run loop (v0.1.7).
                self.commandPump.submit(command)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Actions

    /// Explicit user takeover of any reflected CLI hold. Returns whether one was
    /// active, so the caller can clear the daemon's unsupervised hold (send a
    /// command) rather than leave it orphaned.
    @discardableResult
    private func seizeControl() -> Bool {
        let had = externalHold != nil
        externalHold = nil
        return had
    }

    func resetAuto() {
        seizeControl()
        // resetAuto clears any hold (CLI or app) → daemon .none. This is the
        // no-CLI-knowledge way out of a pinned CLI hold: the Default button, and
        // the escape for someone with loud fans. Unlike selectProfile (where the
        // monitor keeps working and retries every tick), Default takes
        // the monitor hands-off — so it must NOT claim success it didn't get.
        // Send the reset off-main and reflect Silent ONLY once the daemon confirms;
        // on failure, leave the current profile active (so the monitor keeps trying)
        // and log it, rather than a false "Silent, handled" over a dead daemon.
        commandPump.submit(.resetAuto) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                guard ok else {
                    TFLogger.shared.error("Reset to Default failed — daemon unreachable; fans NOT reset")
                    return
                }
                self.activeProfile = .silent
                // Default is a deliberate user click, so it persists Silent — but only
                // here, on the daemon-confirmed success path, never on a failed reset.
                self.persistSelectedProfile(FanProfile.silent.id)
                self.monitor?.switchProfile(.silent)
                self.monitor?.resetFanState()
                TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
            }
        }
    }

    func selectProfile(_ profile: FanProfile) {
        let took = seizeControl()
        activeProfile = profile
        persistSelectedProfile(profile.id)
        monitor?.switchProfile(profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        // Reset to auto when switching to a hands-off profile, OR when taking over
        // a CLI hold (so its unsupervised hold isn't orphaned). Otherwise active
        // profiles let tick() ramp from the current temperature. Off-main one-shot
        // on the pump (never coalesced/reordered).
        if profile.curve.handsOff || took {
            commandPump.submit(.resetAuto)
            // resetAuto hands the fans back to the system — the monitor's
            // running/last-applied tracker must forget its state too.
            monitor?.resetFanState()
        }
    }

    // MARK: - Profile persistence

    /// The user's last explicitly-chosen profile id, so the app reopens to it instead of
    /// always Silent. Written ONLY on a user click (picker, Default) via
    /// `persistSelectedProfile`, never on the monitor's per-tick echo of `activeProfile`
    /// or on watchdog / thermal-floor / crash-recovery fan resets.
    private static let selectedProfileKey = "selectedProfile"

    private func persistSelectedProfile(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.selectedProfileKey)
    }

    /// The profile to restore at launch: the persisted choice resolved against the known
    /// profiles, or Silent when nothing is saved or the id no longer exists.
    private func restoredProfile() -> FanProfile {
        FanProfile.selectable(id: UserDefaults.standard.string(forKey: Self.selectedProfileKey))
    }

    // MARK: - Daemon recovery

    /// Called when the heartbeat first goes unreachable. If the helper is no
    /// longer enabled in SMAppService (revoked in System Settings, or a pending
    /// registration that was never approved) a kickstart cannot help — re-enter
    /// the registration state machine so the banner guides the real fix. When
    /// the registration is still `.enabled` this is a genuine outage and the
    /// existing down banner / kickstart remains the recovery.
    @MainActor
    private func checkRegistrationWhileUnreachable() {
        switch daemonService.status {
        case .enabled:
            // BTM claims enabled yet nothing serves — after an ad-hoc-signed app
            // update the helper's respawn is blocked by a stale launch constraint
            // record while status still reads .enabled (observed live). A bare
            // kickstart cannot refresh constraints; the verified re-register
            // cycle can. Rate-limited; the down banner stays as the manual path.
            if Date().timeIntervalSince(lastDownRegistrationCycle) >= 30 {
                lastDownRegistrationCycle = Date()
                TFLogger.shared.info("Helper unreachable while SMAppService reads .enabled — running verified re-register cycle")
                beginDaemonRecovery()
            }
        default:
            TFLogger.shared.info("Helper unreachable and not enabled in SMAppService — re-entering registration")
            beginHelperRegistration()
        }
    }

    /// Automatic recovery from a helper version mismatch: restart the helper so
    /// launchd respawns the freshly-installed bundle binary, tolerate the down
    /// window while probing for the app's version, and — only if the restart
    /// didn't take — re-register the daemon from the current bundle. Runs OFF the
    /// main thread; the completion hops back to apply the outcome.
    @MainActor
    private func beginDaemonRecovery() {
        guard !daemonRecoveryExhausted else { return }
        guard daemonRecoveryWindow.begin() else { return }   // already recovering
        daemonRecoveryInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = AppState.runDaemonRecovery()
            Task { @MainActor [weak self] in
                guard let self else { return }
                daemonRecoveryWindow.end()
                self.daemonRecoveryInProgress = false
                switch outcome {
                case .recovered:
                    self.daemonVersionMismatch = nil
                    self.daemonRecoveryExhausted = false
                    self.heartbeatFailures = 0
                    self.daemonUnreachable = false
                    self.reengageAfterHelperRecovery(reason: "version recovered")
                case .failed(let version):
                    self.daemonVersionMismatch = version
                    self.daemonRecoveryExhausted = true
                    TFLogger.shared.error("Helper version recovery failed — helper reports \(version)")
                }
            }
        }
    }

    /// Re-take fan control once the helper is back. Shared by both recovery
    /// paths: the version-mismatch restart above and a plain crash/KeepAlive
    /// respawn observed as a heartbeat success. Either way the helper's
    /// supervised hold did not survive the process, so the monitor must rebuild
    /// its tracked runtime state and issue one real write to reconstruct a hold
    /// (`forceReengage` arms that write and defeats the deadband). A CLI hold
    /// wins — never take control from it. `forceReengage` enqueues on the
    /// monitor's own queue, so this stays off the heartbeat's critical path.
    @MainActor
    private func reengageAfterHelperRecovery(reason: String) {
        guard externalHold == nil else {
            TFLogger.shared.info("Helper recovered (\(reason)) — CLI hold active; leaving fan control to the CLI")
            return
        }
        monitor?.forceReengage()
        TFLogger.shared.info("Helper recovered (\(reason)) — monitor force-re-engaging to rebuild the hold")
    }

    /// Re-run the recovery on demand (the mismatch banner's retry action), after
    /// the automatic attempts have been exhausted.
    func retryDaemonRecovery() {
        daemonRecoveryExhausted = false
        beginDaemonRecovery()
    }

    private enum DaemonRecoveryOutcome {
        case recovered
        case failed(version: String)
    }

    /// The blocking recovery sequence, run off-main: (1) `.restart` the helper;
    /// (2) probe the version over a ~10s window for the respawn; (3) if it still
    /// disagrees, unregister + re-register the daemon (which may present the
    /// system authorization prompt) and re-probe; (4) report the final state.
    /// `nonisolated` so it runs entirely off the main actor.
    nonisolated private static func runDaemonRecovery() -> DaemonRecoveryOutcome {
        let client = DaemonClient()

        // (1) Ask the helper to exit; launchd's KeepAlive respawns the bundle
        // binary. A daemon too old to know `.restart` answers unsupported (ok ==
        // false) rather than throwing.
        if let restartResponse = try? client.restart(),
           restartResponse.error == .unsupportedVersion {
            // The running helper predates `.restart`, so it cannot act on the verb.
            // Fall back to the existing launchctl kickstart (the same path the
            // "Restart daemon" button uses) to force a respawn from the current
            // registration before re-registering from the bundle.
            TFLogger.shared.info("Helper predates .restart — falling back to launchctl kickstart")
            AppState.kickstartDaemon()
        }

        // (2) Tolerate the unreachable window. Eight probes spaced a second apart
        // cover ~10s; each bounded connect/read failure costs up to the client
        // timeout, so the real ceiling is a little higher — deliberately generous
        // so a slow respawn isn't mistaken for a failed recovery.
        if probeVersion(client) == ThermalForgeVersion.current {
            return .recovered
        }

        // (3) A respawn from the existing registration still reports the old
        // build — the registered bundle/plist is stale. Re-register from the
        // current bundle. This MUST be a settled, verified cycle: a back-to-back
        // unregister→register races BTM's teardown and can leave the launch
        // constraint record pinned to the OLD binary's signature — the respawn
        // then dies to OS_REASON_CODESIGNING while status still reads .enabled
        // (observed live on an ad-hoc-signed update). Two attempts, 3s apart.
        let service = SMAppService.daemon(plistName: DaemonBundlePlist.filename)
        for cycle in 0..<2 {
            if cycle > 0 { Thread.sleep(forTimeInterval: 3.0) }
            if reregisterVerified(service, client) {
                return .recovered
            }
        }

        // (4) Still wrong after restart + re-registration: report the helper's
        // own last-seen build so the banner is accurate.
        let last = (try? client.request(DaemonRequest(verb: .version)))?.version
        return .failed(version: last ?? "an older build")
    }

    /// One clean unregister → settle → register → serve-verify cycle. True only
    /// when the helper actually answers over the socket with THIS build's
    /// version — `SMAppService.status` alone reported .enabled while the helper
    /// was being killed by a stale launch constraint, so status cannot be the
    /// success signal here.
    nonisolated private static func reregisterVerified(_ service: SMAppService, _ client: DaemonClient) -> Bool {
        try? service.unregister()

        // Settle: wait for the teardown to actually complete (≤5s). Registering
        // while the old item is still being removed re-attaches its stale launch
        // constraint instead of deriving a fresh one for the current binary.
        for _ in 0..<5 {
            if service.status == .notRegistered { break }
            Thread.sleep(forTimeInterval: 1.0)
        }

        do {
            try service.register()
        } catch {
            TFLogger.shared.error("Helper re-registration failed: \(error.localizedDescription)")
            return false
        }

        // Verify by SERVICE, not status: the respawn after a constraint refresh
        // can take a few seconds to appear on the socket.
        return probeVersion(client) == ThermalForgeVersion.current
    }

    /// Poll the daemon's reported version until it matches this build or the
    /// probe window is exhausted. Returns nil if the daemon never answered.
    nonisolated private static func probeVersion(_ client: DaemonClient) -> String? {
        var last: String?
        for attempt in 0..<8 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1.0) }
            if let v = (try? client.request(DaemonRequest(verb: .version)))?.version {
                last = v
                if v == ThermalForgeVersion.current { return v }
            }
        }
        return last
    }

    /// Force the root daemon to restart via launchd, from the "Restart daemon"
    /// button on the unreachable banner. Runs OFF the main thread (it blocks on the
    /// macOS auth dialog). Uses `launchctl kickstart -k` — the standard "restart
    /// this service" — via an Authorization prompt: macOS shows the password dialog
    /// and handles the credential; the app never sees it. On success the next
    /// heartbeat clears `daemonUnreachable`.
    func restartDaemon() {
        DispatchQueue.global(qos: .userInitiated).async {
            AppState.kickstartDaemon()
        }
    }

    /// Force launchd to restart the helper via `launchctl kickstart -k`, through an
    /// admin-authorized `osascript` prompt. Shared by the "Restart daemon" button
    /// and the version-recovery kickstart fallback for a helper too old to
    /// understand `.restart`. Blocking (waits on the auth dialog) — call off-main.
    nonisolated static func kickstartDaemon() {
        // Escaped for AppleScript's `do shell script`; the label is a fixed
        // constant (no user input), so there's nothing untrusted to inject.
        let label = ThermalForgeDaemon.label
        let script = "do shell script \"/bin/launchctl kickstart -k system/\(label)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                TFLogger.shared.info("Restart daemon: launchctl kickstart requested")
            } else {
                // Non-zero includes the user cancelling the auth prompt (-128).
                TFLogger.shared.error("Restart daemon failed (osascript exit \(p.terminationStatus))")
            }
        } catch {
            TFLogger.shared.error("Restart daemon failed to launch: \(error)")
        }
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            launchAtLogin = !launchAtLogin // revert toggle
        }
    }
}

// MARK: - Recovery window flag

/// Lock-guarded flag shared across isolation domains: the version-mismatch
/// recovery (started on the main actor) sets it while it owns a helper restart,
/// and the heartbeat (off-main) reads it to skip its reachability debounce
/// during that deliberate down window. A plain stored property can't be shared
/// across the @MainActor boundary, hence the lock box.
private final class DaemonRecoveryWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    /// Monotonic count of recovery windows that have begun. A heartbeat tick
    /// captures it before its socket I/O; if it changed by completion, a recovery
    /// started (or finished) while the tick was in flight, so its result is stale
    /// and must be discarded rather than incrementing the reachability counter.
    private var generation: UInt64 = 0

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    var currentGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// Atomic `(active, generation)` snapshot so a heartbeat tick can check-and-
    /// capture under ONE lock acquisition. Reading `isActive` then
    /// `currentGeneration` separately can straddle a recovery that begins between
    /// them: the tick sees `active == false`, the recovery then calls `begin()`
    /// and bumps the generation, and the tick captures the NEW generation — so its
    /// completion's generation equality check passes and it applies a pre-recovery
    /// result mid-recovery.
    var snapshot: (active: Bool, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (active, generation)
    }

    /// Claim the window; returns false when one is already in progress.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active { return false }
        active = true
        generation &+= 1
        return true
    }

    func end() {
        lock.lock(); active = false; lock.unlock()
    }
}

/// Single process-wide recovery window — AppState is a singleton in the app.
private let daemonRecoveryWindow = DaemonRecoveryWindow()
