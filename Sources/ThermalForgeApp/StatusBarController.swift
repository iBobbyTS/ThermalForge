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

/// Draws the two-line readout (temp over RPM) directly, centered in the item's
/// drawable area.
///
/// Why not attributedTitle: NSStatusBarButton's cell lays out wrapped titles
/// with single-line metrics — the two-line block drew pushed up out of the
/// item window, leaving the first line clipped at the menu bar's top edge
/// (measured 2026-10-11: text rows 0..12 touching the bar's top edge, second
/// line floating mid-high; setting button.font changed nothing, and swapping
/// the cell broke width auto-sizing). A plain subview that ignores clicks and
/// centers the measured text block itself is the only variant that rendered
/// fully in-bounds.
private final class TwoLineReadoutView: NSView {
    var attributed = NSAttributedString() {
        didSet {
            if attributed != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !attributed.string.isEmpty else { return }
        let size = attributed.size()
        attributed.draw(in: NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusBarController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    /// The orange "daemon out of sync" dot from the old MenuBarLabel — kept as
    /// a plain subview so it rides the native button like it rode the SwiftUI
    /// overlay before.
    private let mismatchDot = NSView()

    /// Owns the two-line readout (see TwoLineReadoutView).
    private let readoutView = TwoLineReadoutView()

    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: "")

            readoutView.autoresizingMask = [.width, .height]
            button.addSubview(readoutView)

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

    /// Font metrics for the readout. 9.5pt SF mono digits, lines tightened a
    /// touch so the block also fits the 24pt menu bars of non-notch displays
    /// (natural spacing measures ~23pt for two lines — zero margin there).
    private static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    private static let lineHeightMultiple: CGFloat = 0.92

    private func refreshButton() {
        guard let button = statusItem.button else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = Self.lineHeightMultiple
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.readoutFont,
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
        readoutView.attributed = title

        // The readout draws itself; the item width is managed here. Monospaced
        // digits keep a given line stable, but "9" → "10" or "°C" → "°F" still
        // changes the widest line, so measure every refresh.
        let blockWidth = ceil(title.size().width)
        let dotVisible = appState.daemonVersionMismatch != nil
        statusItem.length = blockWidth + 8 + (dotVisible ? 7 : 0)
        if readoutView.frame != button.bounds {
            readoutView.frame = button.bounds
        }

        // The dot sits just past the title block's top-right corner (the extra
        // +7 length above reserves the space when it is showing).
        mismatchDot.isHidden = !dotVisible
        mismatchDot.frame.origin = NSPoint(
            x: 4 + blockWidth + 5,
            y: button.bounds.maxY - 7
        )

        // attributedTitle is empty (the cell's multi-line layout is broken —
        // see TwoLineReadoutView), so VoiceOver reads the button via this label.
        button.setAccessibilityLabel(accessibilityText(title.string))
    }

    private func accessibilityText(_ raw: String) -> String {
        let parts = raw.split(separator: "\n").map(String.init)
        switch parts.count {
        case 2:
            return "ThermalForge: \(parts[0]), fan \(parts[1]) RPM"
        case 1:
            return "ThermalForge: \(parts[0])"
        default:
            return "ThermalForge"
        }
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
