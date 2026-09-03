import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

enum HUDStyle: String, CaseIterable, Identifiable {
    case compact
    case expanded
    case edgeStrip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .expanded: return "Expanded"
        case .edgeStrip: return "Edge Strip"
        }
    }
}

enum HUDPlacement: String, CaseIterable, Identifiable {
    case dock
    case rightEdge
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock: return "Beside Dock"
        case .rightEdge: return "Right Edge"
        case .free: return "Free"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let maskEmails = "maskEmails"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyLowLimit = "notifyLowLimit"
        static let notifyOnReset = "notifyOnReset"
        static let lowLimitThreshold = "lowLimitThreshold"
        static let refreshInterval = "refreshInterval"
        static let autoOpenRecommendations = "autoOpenRecommendations"
        static let showOnlyWhileCodexRuns = "showOnlyWhileCodexRuns"
        static let compactHUD = "compactHUD"
        static let attachHUDToDock = "attachHUDToDock"
        static let hudStyle = "hudStyle"
        static let hudPlacement = "hudPlacement"
        static let previousHUDPlacement = "previousHUDPlacement"
        static let detachedHUDOriginX = "detachedHUDOriginX"
        static let detachedHUDOriginY = "detachedHUDOriginY"
        static let edgeHUDCenterY = "edgeHUDCenterY"
        static let activeTaskDetection = "activeTaskDetection"

        static let all = [
            maskEmails,
            notificationsEnabled,
            notifyLowLimit,
            notifyOnReset,
            lowLimitThreshold,
            refreshInterval,
            autoOpenRecommendations,
            showOnlyWhileCodexRuns,
            compactHUD,
            attachHUDToDock,
            hudStyle,
            hudPlacement,
            previousHUDPlacement,
            detachedHUDOriginX,
            detachedHUDOriginY,
            edgeHUDCenterY,
            activeTaskDetection
        ]
    }

    static let refreshIntervals: [TimeInterval] = [30, 60, 120, 300]
    static let lowLimitThresholds = [5, 10, 20]

    @Published var maskEmails: Bool {
        didSet { defaults.set(maskEmails, forKey: Key.maskEmails) }
    }
    @Published private(set) var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    @Published var notifyLowLimit: Bool {
        didSet { defaults.set(notifyLowLimit, forKey: Key.notifyLowLimit) }
    }
    @Published var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Key.notifyOnReset) }
    }
    @Published var lowLimitThreshold: Int {
        didSet { defaults.set(lowLimitThreshold, forKey: Key.lowLimitThreshold) }
    }
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }
    @Published var autoOpenRecommendations: Bool {
        didSet { defaults.set(autoOpenRecommendations, forKey: Key.autoOpenRecommendations) }
    }
    @Published var showOnlyWhileCodexRuns: Bool {
        didSet { defaults.set(showOnlyWhileCodexRuns, forKey: Key.showOnlyWhileCodexRuns) }
    }
    @Published private(set) var hudStyle: HUDStyle
    @Published private(set) var hudPlacement: HUDPlacement
    @Published var activeTaskDetection: Bool {
        didSet { defaults.set(activeTaskDetection, forKey: Key.activeTaskDetection) }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var settingsError: String?

    private let defaults: UserDefaults
    private var previousHUDPlacement: HUDPlacement

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDefaultsIfNeeded(in: defaults)

        let storedStyle = defaults.string(forKey: Key.hudStyle).flatMap(HUDStyle.init(rawValue:))
        let legacyCompact = (defaults.object(forKey: Key.compactHUD) as? Bool) ?? true
        let initialStyle = storedStyle ?? (legacyCompact ? .compact : .expanded)

        let storedPlacement = defaults.string(forKey: Key.hudPlacement)
            .flatMap(HUDPlacement.init(rawValue:))
        let legacyAttached = (defaults.object(forKey: Key.attachHUDToDock) as? Bool) ?? true
        let migratedPlacement = storedPlacement ?? (legacyAttached ? .dock : .free)
        let storedPreviousPlacement = defaults.string(forKey: Key.previousHUDPlacement)
            .flatMap(HUDPlacement.init(rawValue:))
        let initialPreviousPlacement = storedPreviousPlacement
            ?? (migratedPlacement == .rightEdge ? .dock : migratedPlacement)

        defaults.register(defaults: [
            Key.maskEmails: false,
            Key.notificationsEnabled: false,
            Key.notifyLowLimit: true,
            Key.notifyOnReset: true,
            Key.lowLimitThreshold: 10,
            Key.refreshInterval: 60.0,
            Key.autoOpenRecommendations: true,
            Key.showOnlyWhileCodexRuns: false,
            Key.compactHUD: true,
            Key.attachHUDToDock: true,
            Key.activeTaskDetection: false
        ])

        hudStyle = initialStyle
        hudPlacement = initialStyle == .edgeStrip ? .rightEdge : migratedPlacement
        previousHUDPlacement = initialPreviousPlacement

        maskEmails = defaults.bool(forKey: Key.maskEmails)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        notifyLowLimit = defaults.bool(forKey: Key.notifyLowLimit)
        notifyOnReset = defaults.bool(forKey: Key.notifyOnReset)

        let storedThreshold = defaults.integer(forKey: Key.lowLimitThreshold)
        lowLimitThreshold = Self.lowLimitThresholds.contains(storedThreshold)
            ? storedThreshold
            : 10

        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = Self.refreshIntervals.contains(storedInterval)
            ? storedInterval
            : 60

        autoOpenRecommendations = defaults.bool(forKey: Key.autoOpenRecommendations)
        showOnlyWhileCodexRuns = defaults.bool(forKey: Key.showOnlyWhileCodexRuns)
        activeTaskDetection = defaults.bool(forKey: Key.activeTaskDetection)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        persistHUDConfiguration()
    }

    private static func migrateLegacyDefaultsIfNeeded(in defaults: UserDefaults) {
        guard defaults === UserDefaults.standard,
              let bundleIdentifier = Bundle.main.bundleIdentifier,
              let legacyDomain = defaults.persistentDomain(forName: "local.codex.limit-hud") else {
            return
        }

        let currentDomain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        guard !Key.all.contains(where: { currentDomain[$0] != nil }) else { return }

        for key in Key.all {
            if let value = legacyDomain[key] {
                defaults.set(value, forKey: key)
            }
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    func setHUDStyle(_ style: HUDStyle) {
        guard style != hudStyle else { return }

        if style == .edgeStrip {
            previousHUDPlacement = hudPlacement
            hudPlacement = .rightEdge
        } else if hudStyle == .edgeStrip {
            hudPlacement = previousHUDPlacement
        }

        hudStyle = style
        persistHUDConfiguration()
    }

    func setHUDPlacement(_ placement: HUDPlacement) {
        guard hudStyle != .edgeStrip, placement != hudPlacement else { return }
        hudPlacement = placement
        previousHUDPlacement = placement
        persistHUDConfiguration()
    }

    private func persistHUDConfiguration() {
        defaults.set(hudStyle.rawValue, forKey: Key.hudStyle)
        defaults.set(hudPlacement.rawValue, forKey: Key.hudPlacement)
        defaults.set(previousHUDPlacement.rawValue, forKey: Key.previousHUDPlacement)

        // Keep the legacy values current so downgrading does not unexpectedly
        // reset an existing user's layout.
        defaults.set(hudStyle == .compact, forKey: Key.compactHUD)
        defaults.set(hudPlacement == .dock, forKey: Key.attachHUDToDock)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = error.localizedDescription
        }
    }

    func requestAccessibilityAccess() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var detachedHUDOrigin: CGPoint? {
        guard defaults.object(forKey: Key.detachedHUDOriginX) != nil,
              defaults.object(forKey: Key.detachedHUDOriginY) != nil else {
            return nil
        }
        return CGPoint(
            x: defaults.double(forKey: Key.detachedHUDOriginX),
            y: defaults.double(forKey: Key.detachedHUDOriginY)
        )
    }

    func saveDetachedHUDOrigin(_ origin: CGPoint) {
        defaults.set(origin.x, forKey: Key.detachedHUDOriginX)
        defaults.set(origin.y, forKey: Key.detachedHUDOriginY)
    }

    var edgeHUDCenterY: CGFloat? {
        guard defaults.object(forKey: Key.edgeHUDCenterY) != nil else { return nil }
        return defaults.double(forKey: Key.edgeHUDCenterY)
    }

    func saveEdgeHUDCenterY(_ centerY: CGFloat) {
        defaults.set(centerY, forKey: Key.edgeHUDCenterY)
    }

    func displayEmail(_ email: String?) -> String? {
        guard let email, maskEmails else { return email }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return email.first.map { "\($0)•••" }
        }
        let local = parts[0]
        let first = local.first.map(String.init) ?? "•"
        return "\(first)•••@\(parts[1])"
    }
}
