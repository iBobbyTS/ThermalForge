//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import Darwin
import SwiftUI
import ThermalForgeCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the menu bar item and the popover panel (see StatusBarController).
    @MainActor private var statusBar: StatusBarController?

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
        statusBar = StatusBarController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
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

@main
struct ThermalForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // The menu bar presence lives in AppDelegate (StatusBarController:
        // NSStatusItem + NSPopover). MenuBarExtra(.window) was replaced because
        // its panel height grows with content but never shrinks back — a
        // transient banner (daemon down +137pt) left a permanent dead region
        // at the bottom of the menu. A bare Settings scene keeps @main valid.
        Settings {
            EmptyView()
        }
    }
}
