//
//  MenuBarView.swift
//  ThermalForge
//
//  Menu bar dropdown content.
//

import SwiftUI
import ThermalForgeCore

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("ThermalForge")
                    .font(.headline)
                Spacer()
                stateIndicator
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Helper registration takes top priority: until the privileged helper
            // is registered and approved, nothing can control the fans. The
            // transient checking/registering states need no banner (the system
            // auth prompt is visible on its own).
            switch appState.helperRegistration {
            case .requiresApproval, .failed:
                HelperRegistrationBanner(
                    status: appState.helperRegistration,
                    onOpenSettings: { appState.openLoginItemsSettings() },
                    onRetry: { appState.retryHelperRegistration() }
                )
                Divider()
            default:
                if appState.daemonUnreachable {
                    // Daemon not answering — nothing in the app can touch the fans,
                    // so this takes over the top of the menu and offers a one-click
                    // fix. The version/hold banners are moot while it's unreachable.
                    DaemonDownBanner(onRestart: { appState.restartDaemon() })
                    Divider()
                } else {
                    // Update-needed banner — shown whenever the daemon is out of
                    // sync. Persistent (no dismiss): a stale daemon keeps nagging.
                    if let daemonVersion = appState.daemonVersionMismatch {
                        DaemonUpdateBanner(
                            daemonVersion: daemonVersion,
                            recoveryInProgress: appState.daemonRecoveryInProgress,
                            onRetry: { appState.retryDaemonRecovery() }
                        )
                        Divider()
                    }

                    // CLI-hold banner — the app is reflecting a hold set from the
                    // terminal and won't adjust fans until the user takes over. The
                    // Default button (or picking a profile) releases it.
                    if let hold = appState.externalHold {
                        ExternalHoldBanner(hold: hold)
                        Divider()
                    }

                    // Update-available banner — informational, lowest priority.
                    // Suppressed while "Update needed" (daemon out of sync) shows, so
                    // two update-ish banners never stack; coexists with a CLI hold.
                    if appState.daemonVersionMismatch == nil, let update = appState.availableUpdate {
                        UpdateAvailableBanner(update: update, onDismiss: { appState.dismissUpdate() })
                        Divider()
                    }
                }
            }

            // Fan speeds
            if let status = appState.latestStatus {
                SectionHeader(title: "FANS")
                ForEach(status.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(fan.actualRPM) RPM")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }

                Divider().padding(.vertical, 4)

                // Temperatures
                SectionHeader(title: "TEMPERATURES")
                TemperatureRow(label: "CPU", value: peakTemp(prefixes: ["TC", "Tp"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "GPU", value: peakTemp(prefixes: ["TG", "Tg"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "RAM", value: peakTemp(prefixes: ["TR", "Tm", "TM"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "SSD", value: peakTemp(prefixes: ["TH"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "Ambient", value: peakTemp(prefixes: ["TA"]), fahrenheit: appState.useFahrenheit)
            } else {
                Text("Reading sensors...")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider().padding(.vertical, 4)

            // Profile picker
            SectionHeader(title: "PROFILE")
            Picker("Profile", selection: Binding(
                get: { appState.activeProfile.id },
                set: { id in
                    if let profile = FanProfile.builtIn.first(where: { $0.id == id }) {
                        appState.selectProfile(profile)
                    }
                }
            )) {
                ForEach(FanProfile.builtIn) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if !profile.curve.handsOff {
                            if profile.curve.alwaysOn {
                                // Max: always 100%, no temperature conditions
                                Text("100% always")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let unit = appState.useFahrenheit ? "F" : "C"
                                if profile.curve.instantEngage {
                                    // Instant engage: show trigger temp
                                    let startC = profile.curve.startTemp
                                    let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                    Text("\(Int(startDisp))°\(unit) instant")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    let startC = profile.curve.startTemp
                                    let ceilC = profile.curve.ceilingTemp
                                    let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                    let ceilDisp = appState.useFahrenheit ? ceilC * 9 / 5 + 32 : ceilC
                                    Text("\(Int(startDisp))→\(Int(ceilDisp))°\(unit)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Quick actions
            Button(action: { appState.resetAuto() }) {
                Label("Default", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Footer
            Toggle("°F / °C", isOn: $appState.useFahrenheit)
                .padding(.horizontal, 12)
            Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                .padding(.horizontal, 12)

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit ThermalForge")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(width: 260)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stateIndicator: some View {
        switch appState.monitorState {
        case .safetyOverride:
            Label("SAFETY", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .active(let name):
            Label(name, systemImage: "fan.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            Label("Idle", systemImage: "fan")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func peakTemp(prefixes: [String]) -> Float? {
        guard let temps = appState.latestStatus?.temperatures else { return nil }
        let values = temps.filter { key, _ in prefixes.contains(where: { key.hasPrefix($0) }) }.values
        return values.max()
    }
}

// MARK: - Subviews

/// Banner shown when a hold was set from the CLI. Explains what's pinned and how
/// to release it without needing to know any terminal commands.
private struct ExternalHoldBanner: View {
    let hold: DaemonHoldState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Fans held from Terminal", systemImage: "terminal.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)

            Text(describe(hold.command))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Press Default below (or pick a profile) to release.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func describe(_ command: String?) -> String {
        let parts = (command ?? "").split(separator: " ").map(String.init)
        switch parts.first {
        // Approximate language on purpose: the held value is the fan's TARGET, but the
        // RPM shown in the fan rows is the actual tach, which hovers ~1% around it. Exact
        // wording ("pinned to 3500") next to a row reading 3488/3512 looks like a bug.
        case "max":
            return "Fans are held at maximum. The app won't adjust them until you take over."
        case "set" where parts.count > 1:
            return "Fans are held at about \(parts[1]) RPM. The app won't adjust them until you take over."
        case "setfan" where parts.count > 2:
            return "Fan \(parts[1]) is held at about \(parts[2]) RPM. The app won't adjust fans until you take over."
        default:
            return "Fans are held manually. The app won't adjust them until you take over."
        }
    }
}

/// Non-modal in-menu banner telling the user the background helper is out of
/// sync. The app fixes this itself (restart → re-register); this only reports
/// progress and, on failure, offers the retry — never a Terminal command.
private struct DaemonUpdateBanner: View {
    let daemonVersion: String
    let recoveryInProgress: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(recoveryInProgress ? "Updating background service" : "Background service update failed",
                  systemImage: recoveryInProgress ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(recoveryInProgress ? .blue : .orange)

            Text("The background service is running \(daemonVersion), but the app is \(ThermalForgeVersion.current).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if recoveryInProgress {
                Text("ThermalForge is restarting the background service and re-syncing it automatically. Fan control returns when it finishes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Automatic recovery couldn't update it. Try again — macOS may ask you to approve the helper.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onRetry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((recoveryInProgress ? Color.blue : Color.orange).opacity(0.12))
    }
}

/// Shown when the embedded privileged helper still needs user approval in
/// System Settings (or registration/approval failed). Until it's approved the
/// app cannot control fans, so this sits at the top of the menu.
private struct HelperRegistrationBanner: View {
    let status: AppState.HelperRegistrationStatus
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "lock.shield.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onOpenSettings) {
                Label("Open Login Items Settings", systemImage: "gearshape")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.top, 2)

            HStack {
                Text("After you approve it, this updates on its own.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var title: String {
        switch status {
        case .requiresApproval: return "Approve background helper"
        case .failed: return "Background helper unavailable"
        default: return "Setting up background helper"
        }
    }

    private var message: String {
        switch status {
        case .requiresApproval:
            return "macOS needs your approval before ThermalForge can control fans. Enable ThermalForge under Login Items & Extensions."
        case .failed(let reason):
            return "ThermalForge couldn't register its background helper, so fan control is unavailable. \(reason)"
        default:
            return "Setting up the background service…"
        }
    }
}

/// Shown when a newer ThermalForge release exists than the installed build. Purely
/// informational (blue, not the orange "Update needed"): it tells the user an update
/// shipped and how to get it — replacing the app bundle brings the embedded helper
/// with it. Dismissible per-version via "Later".
private struct UpdateAvailableBanner: View {
    let update: AvailableUpdate
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Update available", systemImage: "arrow.down.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.blue)

            Text("ThermalForge \(update.version) is available. You have \(ThermalForgeVersion.current).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Download the new ThermalForge.app and replace the one in Applications — the embedded helper updates with it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)

            Text("Built from source? Rebuild and run  ./setup.sh")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let url = URL(string: update.url) {
                    Link("What's new", destination: url)
                        .font(.caption2)
                }
                Spacer()
                Button("Later", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12))
    }
}

/// Shown when the daemon has stopped answering — fan control is impossible until
/// it's back. Offers a one-click restart (launchd kickstart via a macOS admin
/// prompt). The daemon's KeepAlive usually restarts it on its own, so this is the
/// manual nudge for the rare stuck case; it never asks the user to reinstall.
private struct DaemonDownBanner: View {
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fan control unavailable", systemImage: "exclamationmark.octagon.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)

            Text("The background service isn't responding, so profiles and Default can't change the fans right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onRestart) {
                Label("Restart daemon", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.top, 2)

            Text("Asks for your password once. If it doesn't come back right away, it will keep retrying on its own.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }
}

private struct TemperatureRow: View {
    let label: String
    let value: Float?
    var fahrenheit: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let tempC = value {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                let unit = fahrenheit ? "F" : "C"
                Text("\(String(format: "%.1f", display))°\(unit)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(tempColor(tempC))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    /// Color thresholds always based on °C
    private func tempColor(_ temp: Float) -> Color {
        if temp >= 90 { return .red }
        if temp >= 75 { return .orange }
        if temp >= 60 { return .yellow }
        return .primary
    }
}
