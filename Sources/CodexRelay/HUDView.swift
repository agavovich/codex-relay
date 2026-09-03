import AppKit
import SwiftUI

@MainActor
private final class HUDOutsideClickMonitor: ObservableObject {
    private var globalMonitor: Any?

    func start(onOutsideClick: @escaping @MainActor () -> Void) {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            Task { @MainActor in onOutsideClick() }
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}

@MainActor
final class HUDPresentationState: ObservableObject {
    @Published private(set) var style: HUDStyle
    @Published private(set) var isExpanded: Bool
    @Published private(set) var isEdgePinned = false

    private var isEdgeStripHovering = false
    private var isEdgePanelHovering = false
    private var isPopoverPresented = false
    private var edgeTransitionTask: Task<Void, Never>?

    private var isEdgeHovering: Bool {
        isEdgeStripHovering || isEdgePanelHovering
    }

    init(style: HUDStyle) {
        self.style = style
        isExpanded = style == .expanded
    }

    deinit {
        edgeTransitionTask?.cancel()
    }

    func setStyle(_ style: HUDStyle) {
        edgeTransitionTask?.cancel()
        self.style = style
        isEdgePinned = false
        isEdgeStripHovering = false
        isEdgePanelHovering = false
        isExpanded = style == .expanded
    }

    func setEdgeStripHovering(_ hovering: Bool) {
        updateEdgeHover(strip: hovering)
    }

    func setEdgePanelHovering(_ hovering: Bool) {
        updateEdgeHover(panel: hovering)
    }

    private func updateEdgeHover(strip: Bool? = nil, panel: Bool? = nil) {
        guard style == .edgeStrip else { return }
        let wasHovering = isEdgeHovering
        if let strip { isEdgeStripHovering = strip }
        if let panel { isEdgePanelHovering = panel }
        let hovering = isEdgeHovering
        guard hovering != wasHovering else { return }
        edgeTransitionTask?.cancel()
        if hovering {
            setEdgeExpanded(true)
        } else {
            // One short seam guard lets mouseExited on the strip and
            // mouseEntered on the adjacent panel settle in the right order.
            // There is no visible transition animation after this check.
            scheduleEdgeExpansion(expanded: false, delay: 0.02)
        }
    }

    func toggleEdgePin() {
        guard style == .edgeStrip else { return }
        edgeTransitionTask?.cancel()
        isEdgePinned.toggle()
        setEdgeExpanded(isEdgePinned || isEdgeHovering || isPopoverPresented)
    }

    func setPopoverPresented(_ presented: Bool) {
        isPopoverPresented = presented
        guard style == .edgeStrip else { return }
        edgeTransitionTask?.cancel()
        if presented {
            setEdgeExpanded(true)
        } else if !isEdgePinned, !isEdgeHovering {
            scheduleEdgeExpansion(expanded: false, delay: 0.02)
        }
    }

    func showExpandedPreview() {
        edgeTransitionTask?.cancel()
        if style == .edgeStrip {
            setEdgeExpanded(true)
        } else {
            isExpanded = true
        }
    }

    private func scheduleEdgeExpansion(expanded: Bool, delay: TimeInterval) {
        edgeTransitionTask?.cancel()
        if !expanded, isEdgePinned || isPopoverPresented { return }

        edgeTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if expanded {
                guard self.isEdgeHovering else { return }
            } else {
                guard !self.isEdgeHovering, !self.isEdgePinned, !self.isPopoverPresented else {
                    return
                }
            }
            self.setEdgeExpanded(expanded)
        }
    }

    private func setEdgeExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }
}

@MainActor
final class HUDWindowDragHandler {
    private weak var panel: NSPanel?
    private let settings: AppSettings
    private var initialOrigin: NSPoint?

    init(panel: NSPanel, settings: AppSettings) {
        self.panel = panel
        self.settings = settings
    }

    func update(translation: CGSize) {
        guard settings.hudPlacement != .dock, let panel else { return }
        let origin = initialOrigin ?? panel.frame.origin
        initialOrigin = origin
        let x = settings.hudPlacement == .free
            ? origin.x + translation.width
            : origin.x
        panel.setFrameOrigin(NSPoint(x: x, y: origin.y - translation.height))

        if settings.hudPlacement == .rightEdge {
            settings.saveEdgeHUDCenterY(panel.frame.midY)
        }
    }

    func end() {
        guard settings.hudPlacement != .dock, let panel else {
            initialOrigin = nil
            return
        }
        if settings.hudPlacement == .free {
            settings.saveDetachedHUDOrigin(
                CGPoint(x: panel.frame.minX, y: panel.frame.minY)
            )
        } else {
            settings.saveEdgeHUDCenterY(panel.frame.midY)
        }
        initialOrigin = nil
    }
}

enum HUDMetrics {
    static let baseHeight: CGFloat = 52
    static let baseCornerRadius: CGFloat = 15
    static let sectionInset: CGFloat = 12
    static let brandWidth: CGFloat = 50
    static let singleWindowWidth: CGFloat = 121
    static let multiWindowWidth: CGFloat = 108
    static let brandSectionWidth = brandWidth + sectionInset * 2
    static let baseWidth: CGFloat = brandSectionWidth
        + 2 * (1 + multiWindowWidth + sectionInset * 2)
    static let edgeCollapsedWidth: CGFloat = 8
    static let edgePanelWidth: CGFloat = 214
    static let edgePanelHeight: CGFloat = 240

    static func expandedBaseWidth(windowCount: Int) -> CGFloat {
        switch windowCount {
        case 0: return 280
        case 1:
            return brandSectionWidth
                + 1
                + singleWindowWidth
                + sectionInset * 2
        case 2: return baseWidth
        default:
            return brandSectionWidth
                + CGFloat(windowCount) * (1 + multiWindowWidth + sectionInset * 2)
        }
    }

}

struct HUDView: View {
    @ObservedObject var store: LimitStore
    @ObservedObject var presentationState: HUDPresentationState
    let dragHandler: HUDWindowDragHandler

    @State private var showingAccounts = false
    @State private var openPopoverInSettings = false
    @StateObject private var outsideClickMonitor = HUDOutsideClickMonitor()

    init(
        store: LimitStore,
        presentationState: HUDPresentationState,
        dragHandler: HUDWindowDragHandler
    ) {
        self.store = store
        self.presentationState = presentationState
        self.dragHandler = dragHandler
    }

    private var isExpanded: Bool {
        presentationState.isExpanded
    }

    private var isEdgeStrip: Bool {
        presentationState.style == .edgeStrip
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let cornerRadius = isEdgeStrip
                ? 16
                : min(
                    size.height / 2,
                    HUDMetrics.baseCornerRadius * size.height / HUDMetrics.baseHeight
                )

            hudSurface(size: size, cornerRadius: cornerRadius)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isEdgeStrip {
                presentationState.toggleEdgePin()
            } else {
                openAccounts()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    dragHandler.update(translation: value.translation)
                }
                .onEnded { _ in
                    dragHandler.end()
                }
        )
        .onHover { hovering in
            presentationState.setEdgePanelHovering(hovering)
        }
        .onChange(of: showingAccounts) { isPresented in
            presentationState.setPopoverPresented(isPresented)
            if isPresented {
                outsideClickMonitor.start {
                    showingAccounts = false
                }
            } else {
                outsideClickMonitor.stop()
            }
        }
        .onChange(of: store.accountPopoverRequest) { _ in
            openPopoverInSettings = false
            showingAccounts = true
        }
        .onChange(of: store.activeProfile.id) { _ in
            showingAccounts = false
        }
        .onDisappear {
            outsideClickMonitor.stop()
        }
        .popover(
            isPresented: $showingAccounts,
            arrowEdge: isEdgeStrip ? .trailing : .bottom
        ) {
            AccountPopoverView(
                store: store,
                startsInSettings: openPopoverInSettings
            ) {
                showingAccounts = false
            }
        }
    }

    private func openAccounts() {
        openPopoverInSettings = false
        showingAccounts.toggle()
    }

    private func openSettings() {
        openPopoverInSettings = true
        showingAccounts = true
    }

    @ViewBuilder
    private func hudSurface(size: CGSize, cornerRadius: CGFloat) -> some View {
        if isEdgeStrip {
            edgeSurface(size: size, cornerRadius: cornerRadius)
        } else {
            standardSurface(size: size, cornerRadius: cornerRadius)
        }
    }

    @ViewBuilder
    private func standardSurface(size: CGSize, cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            standardContent(size: size)
                .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
                .background { standardDarkeningLayer(cornerRadius: cornerRadius) }
        } else {
            standardContent(size: size)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay { standardDarkeningLayer(cornerRadius: cornerRadius) }
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(isExpanded ? 0.20 : 0.14),
                                    lineWidth: 0.75
                                )
                        }
                }
        }
    }

    @ViewBuilder
    private func edgeSurface(size: CGSize, cornerRadius _: CGFloat) -> some View {
        edgeContent(size: size)
    }

    private func standardContent(size: CGSize) -> some View {
        let expandedBaseWidth = HUDMetrics.expandedBaseWidth(
            windowCount: store.snapshot?.displayWindows.count ?? 0
        )
        let expandedScale = min(
            size.width / expandedBaseWidth,
            size.height / HUDMetrics.baseHeight
        )

        return ZStack(alignment: .trailing) {
            if isExpanded {
                expandedContent(baseWidth: expandedBaseWidth)
                    .scaleEffect(expandedScale, anchor: .trailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                CollapsedLimitView(
                    window: store.snapshot?.preferredHUDWindow,
                    hasError: store.errorMessage != nil
                )
                .help("Manage accounts")
                .transition(.opacity)
            }
        }
        // The expanded content is scaled from its trailing edge. Keep the
        // unscaled layout frame trailing-aligned too; centering this wrapper
        // shifts the entire rendered HUD left by half the scale delta.
        .frame(width: size.width, height: size.height, alignment: .trailing)
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private func edgeContent(size: CGSize) -> some View {
        edgeExpandedContent
            .frame(width: size.width, height: size.height)
    }

    private var edgeExpandedContent: some View {
        VStack(spacing: 7) {
            edgeAccountSummary

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)

            if let snapshot = store.snapshot, !snapshot.displayWindows.isEmpty {
                ForEach(Array(snapshot.displayWindows.enumerated()), id: \.offset) { _, window in
                    edgeLimitRow(window)
                }
            } else {
                loadingState
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            }

            Spacer(minLength: 0)

            edgeResetCredits

            edgeActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var edgeAccountSummary: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08))
                Image(systemName: "person.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(store.activeProfile.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(store.planType?.uppercased() ?? "CODEX")
                    if store.resetCreditCount > 0 {
                        Text("↻\(store.resetCreditCount)")
                            .foregroundStyle(.mint)
                    }
                }
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

                if let recommendation = store.switchRecommendation,
                   let profile = store.profile(for: recommendation.profileID),
                   profile.id != store.activeProfile.id {
                    Text("BEST: \(profile.displayName)")
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.mint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Button {
                presentationState.toggleEdgePin()
            } label: {
                Image(systemName: presentationState.isEdgePinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(presentationState.isEdgePinned ? "Unpin panel" : "Keep panel open")
        }
        .frame(maxWidth: .infinity)
    }

    private var edgeActions: some View {
        HStack(spacing: 6) {
            edgeActionButton("person.2.fill", title: "Accounts") {
                openAccounts()
            }
            edgeActionButton("arrow.clockwise", title: "Refresh") {
                store.refresh()
            }
            edgeActionButton("gearshape.fill", title: "Settings") {
                openSettings()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func edgeActionButton(
        _ systemName: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 7.5, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity, minHeight: 29)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func edgeLimitRow(_ window: RateLimitWindow) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayTitle)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(edgeTint(for: window.remainingPercent))
                        .frame(
                            width: geometry.size.width
                                * max(0.025, window.remainingPercent / 100)
                        )
                }
            }
            .frame(height: 5)

            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                Text(RateLimitCountdown.text(until: window.resetsAt, now: store.now))
                Spacer()
            }
            .font(.system(size: 8.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var edgeResetCredits: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.counterclockwise.circle")
            Text("RESET CREDITS")
            Spacer()
            Text("\(store.resetCreditCount)")
                .foregroundStyle(store.resetCreditCount > 0 ? .mint : .secondary)
        }
        .font(.system(size: 8, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private func edgeTint(for remaining: Double) -> Color {
        switch remaining {
        case ..<25: return .red
        case ..<50: return .yellow
        default: return .white
        }
    }

    private func standardDarkeningLayer(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(isExpanded ? 0.32 : 0.23),
                        Color.black.opacity(isExpanded ? 0.37 : 0.27)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private func expandedContent(baseWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            brand
                .fixedSize()
                .frame(
                    width: HUDMetrics.brandSectionWidth,
                    height: HUDMetrics.baseHeight,
                    alignment: .center
                )

            if let snapshot = store.snapshot {
                let windows = snapshot.displayWindows

                if windows.isEmpty {
                    separator
                    emptyWindowState
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        separator
                        LimitCell(
                            window: window,
                            now: store.now,
                            width: windows.count == 1
                                ? HUDMetrics.singleWindowWidth
                                : HUDMetrics.multiWindowWidth
                        )
                        .frame(
                            width: (windows.count == 1
                                ? HUDMetrics.singleWindowWidth
                                : HUDMetrics.multiWindowWidth)
                                + HUDMetrics.sectionInset * 2,
                            alignment: .center
                        )
                    }
                }
            } else {
                separator
                loadingState
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: baseWidth, height: HUDMetrics.baseHeight)
    }

    private var brand: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.08))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }

                if let icon = CodexIconAsset.monochrome {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(Color.white)

                    CodexTerminalGlyph()
                        .stroke(
                            Color.white,
                            style: StrokeStyle(
                                lineWidth: 1.55,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.16), radius: 0.35, y: 0.25)
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.planType?.uppercased() ?? "—")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(spacing: 3) {
                    if store.resetCreditCount > 0 {
                        Text("↻\(store.resetCreditCount)")
                            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.mint)
                    }

                    if store.errorMessage != nil {
                        Circle()
                            .fill(.red)
                            .frame(width: 4, height: 4)
                    }

                }
            }
        }
        .contentShape(Rectangle())
        .help("Manage accounts")
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.13))
            .frame(width: 1, height: 30)
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.errorMessage == nil ? "Reading limits…" : "No data")
                .font(.system(size: 11, weight: .semibold, design: .rounded))

            Text(store.errorMessage ?? "Connecting to Codex")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyWindowState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No limits reported")
                .font(.system(size: 11, weight: .semibold, design: .rounded))

            Text("Codex returned no active windows")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EdgeStripView: View {
    @ObservedObject var store: LimitStore
    @ObservedObject var presentationState: HUDPresentationState
    let dragHandler: HUDWindowDragHandler

    var body: some View {
        EdgeStripIndicator(
            window: store.snapshot?.preferredHUDWindow,
            hasError: store.errorMessage != nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            presentationState.toggleEdgePin()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    dragHandler.update(translation: value.translation)
                }
                .onEnded { _ in
                    dragHandler.end()
                }
        )
        .onHover { hovering in
            presentationState.setEdgeStripHovering(hovering)
        }
    }
}

private struct EdgeStripIndicator: View {
    let window: RateLimitWindow?
    let hasError: Bool

    var body: some View {
        let remaining = window?.remainingPercent ?? 0
        let maximumHeight: CGFloat = HUDMetrics.edgePanelHeight - 12
        let fillHeight = max(5, maximumHeight * remaining / 100)

        return ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color.primary.opacity(0.22))

            Capsule()
                .fill(window == nil ? (hasError ? Color.red : Color.secondary) : tint(for: remaining))
                .frame(height: window == nil ? 36 : fillHeight)
        }
            .frame(width: 7, height: maximumHeight)
            .shadow(color: Color.black.opacity(0.22), radius: 1.5, x: -0.5, y: 0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                window.map {
                    "\($0.displayTitle), \(Int($0.remainingPercent.rounded())) percent remaining"
                } ?? "Codex limits unavailable"
            )
    }

    private func tint(for remaining: Double) -> Color {
        switch remaining {
        case ..<25: return .red
        case ..<50: return .yellow
        default: return .white
        }
    }
}

private struct CollapsedLimitView: View {
    let window: RateLimitWindow?
    let hasError: Bool

    private var remaining: Double {
        window?.remainingPercent ?? 0
    }

    private var tint: Color {
        guard window != nil else { return .secondary }
        switch remaining {
        case ..<25: return .red
        case ..<50: return .yellow
        default: return .white
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let diameter = max(24, min(geometry.size.width, geometry.size.height) - 14)
            let lineWidth = max(2.5, diameter * 0.095)

            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.045))

                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: lineWidth)

                if window != nil {
                    Circle()
                        .trim(from: 0, to: max(0.002, remaining / 100))
                        .stroke(
                            tint,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }

                Text(window.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—")
                    .font(.system(
                        size: diameter * 0.25,
                        weight: .medium,
                        design: .rounded
                    ))
                    .monospacedDigit()
                    .foregroundStyle(window == nil ? Color.secondary : Color.primary)

                if hasError {
                    Circle()
                        .fill(.red)
                        .frame(width: max(4, diameter * 0.11))
                        .offset(x: diameter * 0.34, y: -diameter * 0.34)
                }
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: remaining)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window?.displayTitle ?? "Codex limit")
            .accessibilityValue(
                window.map { "\(Int($0.remainingPercent.rounded())) percent remaining" }
                    ?? "Unavailable"
            )
        }
    }
}

private struct CodexTerminalGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let xScale = rect.width / 20
        let yScale = rect.height / 20
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * xScale, y: y * yScale)
        }

        var path = Path()
        path.move(to: point(6.2, 7.25))
        path.addLine(to: point(8.65, 10))
        path.addLine(to: point(6.2, 12.75))

        path.move(to: point(10.55, 12.75))
        path.addLine(to: point(14.25, 12.75))
        return path
    }
}

private struct LimitCell: View {
    let window: RateLimitWindow
    let now: Date
    let width: CGFloat

    private var remaining: Double {
        window.remainingPercent
    }

    private var tint: Color {
        switch remaining {
        case ..<25: return .red
        case ..<50: return .yellow
        default: return .white
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.displayTitle)
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 2)

                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: geometry.size.width * remaining / 100)
                }
            }
            .frame(height: 3.5)

            HStack(spacing: 2.5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 6.5, weight: .semibold))
                Text(resetText)
                    .monospacedDigit()
            }
            .font(.system(size: 7.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(width: width)
    }

    private var resetText: String {
        RateLimitCountdown.text(until: window.resetsAt, now: now)
    }
}
