import ApplicationServices
import Foundation
import ServiceManagement

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
    @Published var compactHUD: Bool {
        didSet { defaults.set(compactHUD, forKey: Key.compactHUD) }
    }
    @Published var activeTaskDetection: Bool {
        didSet { defaults.set(activeTaskDetection, forKey: Key.activeTaskDetection) }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var settingsError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDefaultsIfNeeded(in: defaults)
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
            Key.activeTaskDetection: false
        ])

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
        compactHUD = defaults.bool(forKey: Key.compactHUD)
        activeTaskDetection = defaults.bool(forKey: Key.activeTaskDetection)
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
