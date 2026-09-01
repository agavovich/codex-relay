import AppKit
import Combine
import CoreGraphics
import SwiftUI

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class DockPanelController {
    let panel: NSPanel

    private let store: LimitStore
    private let presentationState: HUDPresentationState
    private let screenEdgeInset: CGFloat = 5
    private var placementTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var manuallyHidden = false
    private var restoredDetachedPosition = false
    private var expansionCancellable: AnyCancellable?
    private var layoutCancellable: AnyCancellable?
    private var attachmentCancellable: AnyCancellable?

    init(store: LimitStore) {
        self.store = store
        let presentationState = HUDPresentationState(
            isExpanded: !store.settings.compactHUD
        )
        self.presentationState = presentationState

        let panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: HUDMetrics.baseHeight,
                height: HUDMetrics.baseHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = presentationState.isExpanded
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = !store.settings.attachHUDToDock
        panel.isMovableByWindowBackground = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // Do not use fullScreenAuxiliary: that behavior intentionally places
        // the HUD above full-screen video and other full-screen apps.
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        self.panel = panel
        let dragHandler = HUDWindowDragHandler(panel: panel, settings: store.settings)
        panel.contentView = FirstMouseHostingView(
            rootView: HUDView(
                store: store,
                presentationState: presentationState,
                dragHandler: dragHandler
            )
        )
        expansionCancellable = presentationState.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] expanded in
                self?.setExpanded(expanded)
            }
        layoutCancellable = store.settings.$compactHUD
            .removeDuplicates()
            .dropFirst()
            .sink { [weak presentationState] compact in
                presentationState?.isExpanded = !compact
            }
        attachmentCancellable = store.settings.$attachHUDToDock
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] attached in
                self?.setAttachedToDock(attached)
            }

        let notificationCenter = NotificationCenter.default
        observers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateVisibilityAndPosition() }
            }
        )
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateVisibilityAndPosition() }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.saveDetachedPositionIfNeeded() }
            }
        )

        placementTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateVisibilityAndPosition() }
        }
    }

    deinit {
        placementTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func show() {
        manuallyHidden = false
        updateVisibilityAndPosition()
    }

    func hide() {
        manuallyHidden = true
        panel.orderOut(nil)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func showExpandedPreview() {
        presentationState.isExpanded = true
    }

    private func setExpanded(_ expanded: Bool) {
        panel.hasShadow = expanded
        panel.invalidateShadow()
        reposition(animated: true)
    }

    private func setAttachedToDock(_ attached: Bool) {
        panel.isMovable = !attached
        panel.isMovableByWindowBackground = false
        restoredDetachedPosition = false
        reposition(animated: true)
    }

    private func updateVisibilityAndPosition() {
        guard !manuallyHidden else { return }
        if store.settings.showOnlyWhileCodexRuns, !store.isCodexRunning {
            panel.orderOut(nil)
            return
        }
        if isFrontmostAppFullScreenOnHUDScreen() {
            panel.orderOut(nil)
            return
        }

        reposition()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func reposition(animated: Bool = false) {
        if store.settings.attachHUDToDock {
            repositionAttached(animated: animated)
        } else {
            repositionDetached(animated: animated)
        }
    }

    private func repositionAttached(animated: Bool) {
        guard let screen = preferredScreen() else { return }

        let targetFrame = attachedFrame(for: screen)
        if !panel.frame.nearlyEquals(targetFrame) {
            panel.setFrame(targetFrame, display: true, animate: animated)
        }
    }

    private func attachedFrame(for screen: NSScreen) -> NSRect {

        let preferences = DockPreferences.load()
        let frame = screen.frame
        let visible = screen.visibleFrame
        let dockThickness = effectiveDockThickness(
            preferences: preferences,
            screenFrame: frame,
            visibleFrame: visible
        )
        let size = adaptivePanelSize(
            dockThickness: dockThickness,
            expanded: presentationState.isExpanded,
            windowCount: store.snapshot?.displayWindows.count ?? 0
        )
        var origin = panel.frame.origin

        switch preferences.edge {
        case .bottom:
            origin = NSPoint(
                x: frame.maxX - size.width - screenEdgeInset,
                y: frame.minY + screenEdgeInset
            )

        case .left:
            origin = NSPoint(
                x: frame.maxX - size.width - screenEdgeInset,
                y: frame.minY + screenEdgeInset
            )

        case .right:
            origin = NSPoint(
                x: frame.maxX - dockThickness - size.width - screenEdgeInset,
                y: frame.minY + screenEdgeInset
            )
        }

        return NSRect(origin: origin, size: size)
    }

    private func repositionDetached(animated: Bool) {
        let height = max(40, panel.frame.height)
        let contentScale = min(1.2, height / HUDMetrics.baseHeight)
        let size = NSSize(
            width: presentationState.isExpanded
                ? HUDMetrics.expandedBaseWidth(
                    windowCount: store.snapshot?.displayWindows.count ?? 0
                ) * contentScale
                : height,
            height: height
        )

        var origin = panel.frame.origin
        if !restoredDetachedPosition {
            if let savedOrigin = store.settings.detachedHUDOrigin {
                origin = NSPoint(x: savedOrigin.x, y: savedOrigin.y)
            } else if !panel.isVisible, let screen = preferredScreen() {
                origin = attachedFrame(for: screen).origin
            }
            restoredDetachedPosition = true
        }

        var targetFrame = NSRect(origin: origin, size: size)
        let screen = screen(for: targetFrame) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            targetFrame.origin = targetFrame.clampedOrigin(
                inside: screen.visibleFrame.insetBy(dx: screenEdgeInset, dy: screenEdgeInset)
            )
        }

        if !panel.frame.nearlyEquals(targetFrame) {
            panel.setFrame(targetFrame, display: true, animate: animated)
        }
    }

    private func saveDetachedPositionIfNeeded() {
        guard !store.settings.attachHUDToDock, restoredDetachedPosition else { return }
        store.settings.saveDetachedHUDOrigin(
            CGPoint(x: panel.frame.minX, y: panel.frame.minY)
        )
    }

    private func screen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
    }

    private func effectiveDockThickness(
        preferences: DockPreferences,
        screenFrame frame: NSRect,
        visibleFrame visible: NSRect
    ) -> CGFloat {
        let reservedThickness: CGFloat

        switch preferences.edge {
        case .bottom:
            reservedThickness = visible.minY - frame.minY
        case .left:
            reservedThickness = visible.minX - frame.minX
        case .right:
            reservedThickness = frame.maxX - visible.maxX
        }

        // With auto-hide enabled, visibleFrame does not reserve the Dock area.
        // The background is about one tile plus its surrounding glass padding.
        let estimatedThickness = preferences.tileSize + 20
        return max(reservedThickness, estimatedThickness)
    }

    private func adaptivePanelSize(
        dockThickness: CGFloat,
        expanded: Bool,
        windowCount: Int
    ) -> NSSize {
        // Keep the top aligned with the work-area edge while mirroring the
        // small gap between the Dock glass and the bottom of the display.
        let height = max(40, dockThickness - screenEdgeInset)
        let contentScale = min(1.2, height / HUDMetrics.baseHeight)

        return NSSize(
            width: expanded
                ? HUDMetrics.expandedBaseWidth(windowCount: windowCount) * contentScale
                : height,
            height: height
        )
    }

    private func preferredScreen() -> NSScreen? {
        if let current = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) {
            return current
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func isFrontmostAppFullScreenOnHUDScreen() -> Bool {
        guard let screen = preferredScreen(),
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windowInfo = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let screenBounds = quartzBounds(for: screen.frame)
        let visibleBounds = quartzBounds(for: screen.visibleFrame)
        let tolerance: CGFloat = 3

        return windowInfo.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == frontmostApp.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.01,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(
                      dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                return false
            }

            let spansScreenWidth = bounds.minX <= screenBounds.minX + tolerance
                && bounds.maxX >= screenBounds.maxX - tolerance
            let reachesScreenBottom = bounds.maxY >= screenBounds.maxY - tolerance
            let startsAtOrAboveWorkArea = bounds.minY <= visibleBounds.minY + tolerance
            let extendsIntoReservedArea = bounds.minX < visibleBounds.minX - tolerance
                || bounds.maxX > visibleBounds.maxX + tolerance
                || bounds.minY < visibleBounds.minY - tolerance
                || bounds.maxY > visibleBounds.maxY + tolerance

            return spansScreenWidth
                && reachesScreenBottom
                && startsAtOrAboveWorkArea
                && extendsIntoReservedArea
        }
    }

    private func quartzBounds(for appKitBounds: NSRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? appKitBounds.maxY
        return CGRect(
            x: appKitBounds.minX,
            y: primaryTop - appKitBounds.maxY,
            width: appKitBounds.width,
            height: appKitBounds.height
        )
    }
}

private extension NSRect {
    func nearlyEquals(_ other: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) < tolerance
            && abs(origin.y - other.origin.y) < tolerance
            && abs(size.width - other.size.width) < tolerance
            && abs(size.height - other.size.height) < tolerance
    }

    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }

    func clampedOrigin(inside bounds: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(minX, bounds.minX), max(bounds.minX, bounds.maxX - width)),
            y: min(max(minY, bounds.minY), max(bounds.minY, bounds.maxY - height))
        )
    }
}

private struct DockPreferences {
    enum Edge {
        case bottom
        case left
        case right
    }

    let edge: Edge
    let tileSize: CGFloat

    static func load() -> DockPreferences {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        let edge: Edge

        switch domain["orientation"] as? String {
        case "left": edge = .left
        case "right": edge = .right
        default: edge = .bottom
        }

        let tileSize = (domain["tilesize"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 48

        return DockPreferences(edge: edge, tileSize: tileSize)
    }
}
