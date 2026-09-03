import AppKit
import Combine
import CoreGraphics
import QuartzCore
import SwiftUI

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class HoverTrackingHostingView<Content: View>: FirstMouseHostingView<Content> {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private let verticalInset: CGFloat = 6

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingRect = bounds.insetBy(dx: 0, dy: verticalInset)
        let area = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

private final class NativeMaterialHostingView<Content: View>: NSView {
    private let effectView = NSVisualEffectView()
    private let hostingView: FirstMouseHostingView<Content>
    private var materialEnabled = false
    private var hoverTrackingEnabled = false
    private var hoverTrackingArea: NSTrackingArea?
    var onHoverChanged: ((Bool) -> Void)?

    init(rootView: Content) {
        hostingView = FirstMouseHostingView(rootView: rootView)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        effectView.isHidden = true

        effectView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        guard hoverTrackingEnabled else { return }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverTrackingEnabled else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverTrackingEnabled else { return }
        onHoverChanged?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func setPopoverMaterialEnabled(_ enabled: Bool) {
        guard enabled != materialEnabled else { return }
        materialEnabled = enabled
        effectView.isHidden = !enabled

        layer?.cornerRadius = enabled ? 16 : 0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = enabled
        layer?.borderWidth = enabled ? 0.75 : 0
        updateBorderColor()
    }

    func setHoverTrackingEnabled(_ enabled: Bool) {
        guard enabled != hoverTrackingEnabled else { return }
        hoverTrackingEnabled = enabled
        updateTrackingAreas()
    }

    private func updateBorderColor() {
        layer?.borderColor = materialEnabled
            ? NSColor.separatorColor.withAlphaComponent(0.72).cgColor
            : NSColor.clear.cgColor
    }
}

@MainActor
final class DockPanelController {
    let panel: NSPanel

    private let store: LimitStore
    private let presentationState: HUDPresentationState
    private let edgeStripPanel: NSPanel
    private let panelContentView: NativeMaterialHostingView<HUDView>
    private let screenEdgeInset: CGFloat = 5
    private let edgePanelGap: CGFloat = 0
    private var placementTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var manuallyHidden = false
    private var restoredDetachedPosition = false
    private var restoredRightEdgePosition = false
    private var expansionCancellable: AnyCancellable?
    private var styleCancellable: AnyCancellable?
    private var placementCancellable: AnyCancellable?

    init(store: LimitStore) {
        self.store = store
        let presentationState = HUDPresentationState(
            style: store.settings.hudStyle
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
        panel.hasShadow = presentationState.isExpanded || store.settings.hudStyle == .edgeStrip
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = store.settings.hudPlacement != .dock
        panel.isMovableByWindowBackground = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // Do not use fullScreenAuxiliary: that behavior intentionally places
        // the HUD above full-screen video and other full-screen apps.
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        self.panel = panel

        let edgeStripPanel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: HUDMetrics.edgeCollapsedWidth,
                height: HUDMetrics.edgePanelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        edgeStripPanel.isOpaque = false
        edgeStripPanel.backgroundColor = .clear
        edgeStripPanel.hasShadow = false
        edgeStripPanel.hidesOnDeactivate = false
        edgeStripPanel.isReleasedWhenClosed = false
        edgeStripPanel.isMovable = true
        edgeStripPanel.isMovableByWindowBackground = false
        edgeStripPanel.level = panel.level
        edgeStripPanel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        self.edgeStripPanel = edgeStripPanel

        let dragHandler = HUDWindowDragHandler(panel: panel, settings: store.settings)
        let panelContentView = NativeMaterialHostingView(
            rootView: HUDView(
                store: store,
                presentationState: presentationState,
                dragHandler: dragHandler
            )
        )
        panelContentView.setPopoverMaterialEnabled(store.settings.hudStyle == .edgeStrip)
        panel.contentView = panelContentView
        self.panelContentView = panelContentView
        let edgeDragHandler = HUDWindowDragHandler(
            panel: edgeStripPanel,
            settings: store.settings
        )
        let edgeStripContentView = HoverTrackingHostingView(
            rootView: EdgeStripView(
                store: store,
                presentationState: presentationState,
                dragHandler: edgeDragHandler
            )
        )
        edgeStripPanel.contentView = edgeStripContentView
        panelContentView.onHoverChanged = { [weak self] hovering in
            self?.handleEdgePanelHover(hovering)
        }
        edgeStripContentView.onHoverChanged = { [weak self] hovering in
            self?.handleEdgeStripHover(hovering)
        }
        expansionCancellable = presentationState.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] expanded in
                self?.setExpanded(expanded)
            }
        styleCancellable = store.settings.$hudStyle
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] style in
                self?.setStyle(style)
            }
        placementCancellable = store.settings.$hudPlacement
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] placement in
                self?.setPlacement(placement)
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
        observers.append(
            notificationCenter.addObserver(
                forName: NSWindow.didMoveNotification,
                object: edgeStripPanel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.store.settings.saveEdgeHUDCenterY(self.edgeStripPanel.frame.midY)
                    if self.presentationState.isExpanded {
                        self.repositionEdgeWindows(animated: false)
                    }
                }
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
        edgeStripPanel.orderOut(nil)
    }

    func toggle() {
        let isVisible = store.settings.hudStyle == .edgeStrip
            ? edgeStripPanel.isVisible
            : panel.isVisible
        isVisible ? hide() : show()
    }

    func showExpandedPreview() {
        presentationState.showExpandedPreview()
    }

    private func setExpanded(_ expanded: Bool) {
        if store.settings.hudStyle == .edgeStrip {
            repositionEdgeWindows(animated: false)
            return
        }
        panel.hasShadow = expanded
        panel.invalidateShadow()
        reposition(animated: true)
    }

    private func handleEdgeStripHover(_ hovering: Bool) {
        guard store.settings.hudStyle == .edgeStrip else { return }
        if hovering {
            presentationState.setEdgeStripHovering(true)
            return
        }

        // Panels touch. Mark the destination first when the pointer crosses
        // the seam, so the detail window never needs a timing grace period.
        let panelSeamFrame = panel.frame.insetBy(dx: -0.5, dy: 0)
        if panel.alphaValue > 0, panelSeamFrame.contains(NSEvent.mouseLocation) {
            presentationState.setEdgePanelHovering(true)
        }
        presentationState.setEdgeStripHovering(false)
    }

    private func handleEdgePanelHover(_ hovering: Bool) {
        guard store.settings.hudStyle == .edgeStrip else { return }
        if hovering {
            guard panel.alphaValue > 0, !panel.ignoresMouseEvents else { return }
            presentationState.setEdgePanelHovering(true)
            return
        }

        let stripTrackingFrame = edgeStripPanel.frame
            .insetBy(dx: -0.5, dy: 6)
        if stripTrackingFrame.contains(NSEvent.mouseLocation) {
            presentationState.setEdgeStripHovering(true)
        }
        presentationState.setEdgePanelHovering(false)
    }

    private func setStyle(_ style: HUDStyle) {
        presentationState.setStyle(style)
        panelContentView.setPopoverMaterialEnabled(style == .edgeStrip)
        restoredRightEdgePosition = false
        panel.hasShadow = presentationState.isExpanded
        panel.invalidateShadow()
        if style == .edgeStrip {
            panel.hasShadow = true
            panel.invalidateShadow()
            repositionEdgeWindows(animated: false)
            if !manuallyHidden {
                edgeStripPanel.orderFrontRegardless()
            }
        } else {
            edgeStripPanel.orderOut(nil)
            panelContentView.setHoverTrackingEnabled(false)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            reposition(animated: true)
            if !manuallyHidden {
                panel.orderFrontRegardless()
            }
        }
    }

    private func setPlacement(_ placement: HUDPlacement) {
        panel.isMovable = placement != .dock
        panel.isMovableByWindowBackground = false
        restoredDetachedPosition = false
        restoredRightEdgePosition = false
        reposition(animated: true)
    }

    private func updateVisibilityAndPosition() {
        guard !manuallyHidden else { return }
        if store.settings.showOnlyWhileCodexRuns, !store.isCodexRunning {
            panel.orderOut(nil)
            edgeStripPanel.orderOut(nil)
            return
        }
        if isFrontmostAppFullScreenOnHUDScreen() {
            panel.orderOut(nil)
            edgeStripPanel.orderOut(nil)
            return
        }

        if store.settings.hudStyle == .edgeStrip {
            repositionEdgeWindows(animated: false)
            if !edgeStripPanel.isVisible {
                edgeStripPanel.orderFrontRegardless()
            }
            return
        }

        edgeStripPanel.orderOut(nil)
        reposition()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func reposition(animated: Bool = false) {
        if store.settings.hudStyle == .edgeStrip {
            repositionEdgeWindows(animated: animated)
        } else if store.settings.hudPlacement == .rightEdge {
            repositionRightEdge(animated: animated)
        } else if store.settings.hudPlacement == .dock {
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
            style: store.settings.hudStyle,
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
        let height = HUDMetrics.baseHeight
        let contentScale = min(1.2, height / HUDMetrics.baseHeight)
        let size = NSSize(
            width: store.settings.hudStyle == .expanded
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
        switch store.settings.hudPlacement {
        case .dock:
            return
        case .free:
            guard restoredDetachedPosition else { return }
            store.settings.saveDetachedHUDOrigin(
                CGPoint(x: panel.frame.minX, y: panel.frame.minY)
            )
        case .rightEdge:
            guard restoredRightEdgePosition else { return }
            store.settings.saveEdgeHUDCenterY(
                store.settings.hudStyle == .edgeStrip
                    ? edgeStripPanel.frame.midY
                    : panel.frame.midY
            )
        }
    }

    private func repositionEdgeWindows(animated _: Bool) {
        guard let screen = preferredScreen() else { return }

        let visibleFrame = screen.visibleFrame
        let halfHeight = HUDMetrics.edgePanelHeight / 2
        let requestedCenterY: CGFloat
        if restoredRightEdgePosition {
            requestedCenterY = edgeStripPanel.frame.midY
        } else {
            requestedCenterY = store.settings.edgeHUDCenterY ?? visibleFrame.midY
            restoredRightEdgePosition = true
        }
        let centerY = min(
            max(requestedCenterY, visibleFrame.minY + halfHeight + screenEdgeInset),
            visibleFrame.maxY - halfHeight - screenEdgeInset
        )
        let stripFrame = NSRect(
            x: screen.frame.maxX - HUDMetrics.edgeCollapsedWidth,
            y: centerY - halfHeight,
            width: HUDMetrics.edgeCollapsedWidth,
            height: HUDMetrics.edgePanelHeight
        )
        let detailFrame = NSRect(
            x: stripFrame.minX - edgePanelGap - HUDMetrics.edgePanelWidth,
            y: stripFrame.minY,
            width: HUDMetrics.edgePanelWidth,
            height: HUDMetrics.edgePanelHeight
        )

        if !edgeStripPanel.frame.nearlyEquals(stripFrame) {
            edgeStripPanel.setFrame(stripFrame, display: true)
        }

        if presentationState.isExpanded {
            showEdgeDetail(at: detailFrame)
        } else {
            hideEdgeDetail(from: detailFrame)
        }
    }

    private func showEdgeDetail(at finalFrame: NSRect) {
        panel.level = NSWindow.Level(rawValue: edgeStripPanel.level.rawValue + 1)
        panel.setFrame(finalFrame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        // Keep the window and its material surface alive while collapsed.
        // Showing it now requires no new WindowServer composition.
        panelContentView.setHoverTrackingEnabled(true)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
    }

    private func hideEdgeDetail(from finalFrame: NSRect) {
        panel.setFrame(finalFrame, display: true)
        panelContentView.setHoverTrackingEnabled(false)
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func repositionRightEdge(animated: Bool) {
        guard let screen = preferredScreen() else { return }

        let size = rightEdgePanelSize()
        let visibleFrame = screen.visibleFrame
        let initialCenterY: CGFloat
        if restoredRightEdgePosition {
            initialCenterY = panel.frame.midY
        } else {
            initialCenterY = store.settings.edgeHUDCenterY ?? visibleFrame.midY
            restoredRightEdgePosition = true
        }

        let halfHeight = size.height / 2
        let centerY = min(
            max(initialCenterY, visibleFrame.minY + halfHeight + screenEdgeInset),
            visibleFrame.maxY - halfHeight - screenEdgeInset
        )
        let targetFrame = NSRect(
            x: screen.frame.maxX - size.width - screenEdgeInset,
            y: centerY - halfHeight,
            width: size.width,
            height: size.height
        )

        if !panel.frame.nearlyEquals(targetFrame) {
            panel.setFrame(targetFrame, display: true, animate: animated)
        }
    }

    private func rightEdgePanelSize() -> NSSize {
        return NSSize(
            width: store.settings.hudStyle == .expanded
                ? HUDMetrics.expandedBaseWidth(
                    windowCount: store.snapshot?.displayWindows.count ?? 0
                )
                : HUDMetrics.baseHeight,
            height: HUDMetrics.baseHeight
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
        style: HUDStyle,
        windowCount: Int
    ) -> NSSize {
        // Keep the top aligned with the work-area edge while mirroring the
        // small gap between the Dock glass and the bottom of the display.
        let height = max(40, dockThickness - screenEdgeInset)
        let contentScale = min(1.2, height / HUDMetrics.baseHeight)

        return NSSize(
            width: style == .expanded
                ? HUDMetrics.expandedBaseWidth(windowCount: windowCount) * contentScale
                : height,
            height: height
        )
    }

    private func preferredScreen() -> NSScreen? {
        let referenceFrame = store.settings.hudStyle == .edgeStrip
            ? edgeStripPanel.frame
            : panel.frame
        if let current = NSScreen.screens.first(where: { $0.frame.intersects(referenceFrame) }) {
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
