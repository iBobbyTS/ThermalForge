//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import AppKit
import Darwin
import ThermalForgeCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the menu bar item and the popover panel (see StatusBarController).
    @MainActor private var statusBar: StatusBarController?
    /// Held so applicationWillTerminate can quiesce it — as a launch-local it
    /// was unreachable at quit time, which is exactly how the 2026-10-06 race
    /// happened: the exit resetAuto ran while the monitor's pipeline still had
    /// an in-flight write, which landed one second later and re-pinned the fans.
    @MainActor private var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // R4: the app can have its helper exit out from under an in-flight socket
        // write (a `.restart`). Without this, that closed peer raises SIGPIPE and
        // kills the app. Set process-wide before any daemon socket work; the
        // per-fd SO_NOSIGPIPE in DaemonClient is the belt-and-braces guarantee.
        signal(SIGPIPE, SIG_IGN)

        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
            return
        }

        let appState = AppState()
        self.appState = appState
        statusBar = StatusBarController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quiesce FIRST: stop the monitor's ticks, reject new submits, and
        // drain the pump — otherwise an in-flight ramp write can land at the
        // daemon AFTER the resetAuto below and re-pin the fans in manual
        // (observed 2026-10-06: one setRPM arrived 1s after the exit reset
        // and held max until the daemon watchdog reverted 33s later).
        appState?.prepareForTermination()

        // Reset fans on quit so the daemon doesn't hold stale APP settings — but
        // ONLY if the app owns the hold. A CLI hold (`thermalforge max`) is the
        // user's deliberate, unsupervised choice; quitting the menu bar app must not
        // destroy it — that's the v0.1.7 arbitration feature. Synchronous on purpose:
        // the process is exiting, so an async write would be dropped; both calls are
        // bounded by the sendRaw timeout.
        let client = DaemonClient()
        if let state = try? client.readState(), state.owner == "app" {
            _ = try? client.execute(.resetAuto)
        }
        // owner == "cli" → leave the CLI hold alone; owner == "none" → nothing to reset.
    }
}

/// Pure AppKit entry point — no SwiftUI App shell. A shell requires at least
/// one Scene, and the placeholder `Settings { EmptyView() }` that kept @main
/// valid registered a "Settings…" menu item (⌘,) that opened a blank window
/// whenever the popover made this accessory app's menu bar active. The only
/// UI is the status item + popover; MenuBarView stays SwiftUI via the
/// NSHostingController inside StatusBarController. `main()` never returns —
/// NSApplication.run() blocks until quit — so the local `delegate` stays
/// alive for the app's lifetime alongside NSApplication's unretained delegate.
@MainActor
@main
enum ThermalForgeAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
