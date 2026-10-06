//
//  StatusBarController.swift
//  ThermalForge
//
//  Owns the menu bar presence: NSStatusItem + NSPopover replacing SwiftUI's
//  MenuBarExtra(.window).
//
//  Why not MenuBarExtra: its .window panel grows to fit content but never
//  shrinks back (observed live on macOS 26, darwin 25.6): when a transient
//  banner (e.g. DaemonDownBanner, +137pt) appears and later disappears, the
//  window keeps the grown height and the menu shows a large dead region at
//  the bottom — measured: +137pt stuck after the daemon-down banner cleared.
//  There is no public API to force the window to re-fit. NSPopover re-fits on
//  every open and on every content change while open (resizePopover on
//  objectWillChange), so the panel is always exactly as tall as its content.
//

import AppKit
import Combine
import SwiftUI
import ThermalForgeCore

@MainActor
final class StatusBarController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    /// The orange "daemon out of sync" dot from the old MenuBarLabel — kept as
    /// a plain subview so it rides the native button like it rode the SwiftUI
    /// overlay before.
    private let mismatchDot = NSView()

    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .noImage
            // The title is a two-line block (temp over RPM) — the status-bar
            // cell defaults to single-line and would clamp it.
            button.cell?.usesSingleLineMode = false
            button.cell?.truncatesLastVisibleLine = false
            button.cell?.wraps = true

            mismatchDot.wantsLayer = true
            mismatchDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            mismatchDot.layer?.cornerRadius = 2.5
            mismatchDot.frame = NSRect(x: 0, y: 0, width: 5, height: 5)
            button.addSubview(mismatchDot)
        }

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(appState)
        )

        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshButton()
                // While the popover is open, a banner appearing or clearing
                // must re-fit the popover height immediately — the exact case
                // MenuBarExtra got wrong.
                if self.popover.isShown { self.resizePopover() }
            }
            .store(in: &cancellables)
        refreshButton()
    }

    // MARK: - Button

    private func refreshButton() {
        guard let button = statusItem.button else { return }

        // No icon: the two-line readout IS the button. The monitor state's
        // only remaining menu-bar cue is the orange temp line during a safety
        // override (the icon that used to carry it is gone); the popover's
        // stateIndicator keeps the full detail.
        button.image = nil

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .paragraphStyle: paragraph
        ]

        let title = NSMutableAttributedString(string: "", attributes: attributes)
        if let tempC = appState.maxTemp {
            let fahrenheit = appState.useFahrenheit
            let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
            var tempAttrs = attributes
            if case .safetyOverride = appState.monitorState {
                tempAttrs[.foregroundColor] = NSColor.systemOrange
            }
            title.append(NSAttributedString(
                string: "\(Int(display))°\(fahrenheit ? "F" : "C")\n",
                attributes: tempAttrs
            ))
            if let rpm = appState.latestStatus?.fans.first?.actualRPM {
                title.append(NSAttributedString(string: "\(rpm)", attributes: attributes))
            }
        }
        button.attributedTitle = title

        // The dot sits just past the title block's top-right corner.
        let titleWidth = button.attributedTitle.size().width
        mismatchDot.isHidden = (appState.daemonVersionMismatch == nil)
        mismatchDot.frame.origin = NSPoint(
            x: min(titleWidth + 3, button.bounds.maxX - 5),
            y: button.bounds.maxY - 7
        )
    }

    // MARK: - Popover

    /// Force the popover to exactly the content's natural size. Called on
    /// every open and on every content change while open — this is the fix
    /// for the grow-only MenuBarExtra window. The hosting view is asked for
    /// its fitting size AFTER SwiftUI has processed the state change (the
    /// objectWillChange hop through the main queue guarantees ordering).
    private func resizePopover() {
        guard let content = popover.contentViewController?.view else { return }
        let fit = content.fittingSize
        popover.contentSize = NSSize(width: max(fit.width, 260), height: max(fit.height, 200))
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            resizePopover()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
