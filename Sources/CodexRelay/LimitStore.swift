import AppKit
import Combine
import Foundation

struct ProfileLimitState: Equatable {
    var snapshot: RateLimitSnapshot?
    var resetCreditCount = 0
    var account: CodexAccountInfo?
    var planType: String?
    var errorMessage: String?
    var lastUpdated: Date?

    func compactSummary(now: Date) -> String? {
        guard let snapshot else { return nil }
        let windows = snapshot.displayWindows.map { window in
            let reset = RateLimitCountdown.text(until: window.resetsAt, now: now)
            return "\(window.displayTitle) \(Int(window.remainingPercent.rounded()))% · ↻ \(reset)"
        }
        return windows.isEmpty ? nil : windows.joined(separator: "\n")
    }
}

struct AccountSwitchRecommendation: Equatable, Identifiable {
    let profileID: UUID
    let availableAt: Date
    let usableHeadroom: Double

    var id: UUID { profileID }

    func isAvailable(at now: Date) -> Bool {
        availableAt <= now
    }
}

struct HUDPopoverRequest: Equatable {
    let id = UUID()
    let destination: HUDPopoverDestination
}

enum AccountSwitchAdvisor {
    static func best(
        from candidates: [AccountSwitchRecommendation],
        now: Date
    ) -> AccountSwitchRecommendation? {
        candidates.sorted { lhs, rhs in
            let lhsReady = lhs.isAvailable(at: now)
            let rhsReady = rhs.isAvailable(at: now)
            if lhsReady != rhsReady {
                return lhsReady
            }

            if lhsReady, lhs.usableHeadroom != rhs.usableHeadroom {
                return lhs.usableHeadroom > rhs.usableHeadroom
            }

            if lhs.availableAt != rhs.availableAt {
                return lhs.availableAt < rhs.availableAt
            }

            if lhs.usableHeadroom != rhs.usableHeadroom {
                return lhs.usableHeadroom > rhs.usableHeadroom
            }
            return lhs.profileID.uuidString < rhs.profileID.uuidString
        }.first
    }
}

private struct RecommendationPromptKey: Equatable {
    let activeProfileID: UUID
    let recommendedProfileID: UUID
    let isReady: Bool
}

private enum AccountSwitchError: LocalizedError {
    case limitUnavailable

    var errorDescription: String? {
        "This account is still out of limits. Wait for its blocking window to reset."
    }
}

@MainActor
final class LimitStore: ObservableObject {
    @Published private(set) var snapshot: RateLimitSnapshot?
    @Published private(set) var resetCreditCount = 0
    @Published private(set) var activeProfile: AccountProfile
    @Published private(set) var account: CodexAccountInfo?
    @Published private(set) var planType: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var now = Date()
    @Published private(set) var profileStates: [UUID: ProfileLimitState] = [:]
    @Published private(set) var loginProfileID: UUID?
    @Published private(set) var loginErrorMessage: String?
    @Published private(set) var switchingProfileID: UUID?
    @Published private(set) var signingOutProfileID: UUID?
    @Published private(set) var switchErrorMessage: String?
    @Published private(set) var hudPopoverRequest: HUDPopoverRequest?
    @Published private(set) var switchRecommendation: AccountSwitchRecommendation?
    @Published private(set) var managementErrorMessage: String?
    @Published private(set) var reauthenticatedProfileID: UUID?

    var onNotificationOpen: ((HUDPopoverDestination) -> Void)?

    private let client: CodexAppServerClient
    private let profileStore: AccountProfileStore
    private let desktopController: CodexDesktopController
    var settings: AppSettings
    private let notificationService: LimitNotificationService
    private let activityDetector: CodexActivityDetector
    private var clockTimer: Timer?
    private var settingsCancellable: AnyCancellable?
    private var recommendationPromptKey: RecommendationPromptKey?
    private var notifiedLowLimitKeys: Set<String> = []
    private var nextRefreshAt = Date.distantPast

    init(
        client: CodexAppServerClient = CodexAppServerClient(),
        profileStore: AccountProfileStore? = nil,
        desktopController: CodexDesktopController? = nil,
        settings: AppSettings? = nil,
        notificationService: LimitNotificationService = LimitNotificationService(),
        activityDetector: CodexActivityDetector = CodexActivityDetector()
    ) {
        let profileStore = profileStore ?? AccountProfileStore()
        self.client = client
        self.profileStore = profileStore
        self.desktopController = desktopController ?? CodexDesktopController()
        self.settings = settings ?? AppSettings()
        self.notificationService = notificationService
        self.activityDetector = activityDetector
        activeProfile = profileStore.selectedProfile

        notificationService.onOpenDestination = { [weak self] destination in
            Task { @MainActor in
                self?.onNotificationOpen?(destination)
            }
        }

        settingsCancellable = self.settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.notifiedLowLimitKeys.removeAll()
                self?.nextRefreshAt = .distantPast
            }
        }

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.reevaluateSwitchRecommendation()
                if self.now >= self.nextRefreshAt, !self.isRefreshing {
                    self.refresh()
                }
            }
        }

        refresh()
    }

    deinit {
        clockTimer?.invalidate()
        settingsCancellable?.cancel()
    }

    var profiles: [AccountProfile] {
        profileStore.profiles
    }

    var isAddingAccount: Bool {
        loginProfileID != nil
    }

    var isSwitchingCodex: Bool {
        switchingProfileID != nil || signingOutProfileID != nil
    }

    var isCodexRunning: Bool {
        desktopController.isRunning
    }

    func hasCredential(for profileID: UUID) -> Bool {
        profileStore.hasCredential(for: profileID)
    }

    func isActiveInCodex(_ profileID: UUID) -> Bool {
        profileStore.desktopProfileID == profileID
    }

    func profileState(for profileID: UUID) -> ProfileLimitState? {
        profileStates[profileID]
    }

    func profile(for profileID: UUID) -> AccountProfile? {
        profileStore.profiles.first(where: { $0.id == profileID })
    }

    func requestAccountPopover() {
        requestHUDPopover(.accounts)
    }

    func requestHUDPopover(_ destination: HUDPopoverDestination) {
        hudPopoverRequest = HUDPopoverRequest(destination: destination)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        settings.setNotificationsEnabled(enabled)
        if enabled {
            notificationService.requestAuthorization()
        }
    }

    func setActiveTaskDetection(_ enabled: Bool) {
        settings.activeTaskDetection = enabled
        if enabled {
            settings.requestAccessibilityAccess()
        }
    }

    func detectCodexActivity() async -> CodexActivityState {
        let detector = activityDetector
        let enabled = settings.activeTaskDetection
        return await Task.detached(priority: .userInitiated) {
            detector.detect(enabled: enabled)
        }.value
    }

    func refresh() {
        guard !isRefreshing, signingOutProfileID == nil else { return }
        isRefreshing = true
        nextRefreshAt = Date().addingTimeInterval(settings.refreshInterval)

        let selectedID = profileStore.selectedProfileID
        let orderedProfiles = profileStore.profiles.sorted { lhs, rhs in
            if lhs.id == selectedID { return true }
            if rhs.id == selectedID { return false }
            return lhs.createdAt < rhs.createdAt
        }

        Task {
            for profile in orderedProfiles {
                await refreshProfile(profile)
            }
            isRefreshing = false
            reevaluateSwitchRecommendation()
        }
    }

    func selectProfile(_ profileID: UUID) {
        guard let profile = profileStore.profiles.first(where: { $0.id == profileID }) else {
            return
        }

        profileStore.select(profileID)
        activeProfile = profile
        publishActiveState()
        refresh()
    }

    func activateProfileInCodex(_ profileID: UUID, forceRestart: Bool = false) {
        guard switchingProfileID == nil,
              signingOutProfileID == nil,
              loginProfileID == nil,
              let profile = profileStore.profiles.first(where: { $0.id == profileID }) else {
            return
        }

        if !forceRestart,
           profile.id == profileStore.desktopProfileID,
           desktopController.isRunning {
            switchErrorMessage = nil
            return
        }

        switchingProfileID = profile.id
        switchErrorMessage = nil

        let client = self.client
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try client.fetchAccountUsage(for: profile)
                }.value

                guard result.account != nil else {
                    throw CodexClientError.malformedResponse
                }
                guard let targetSnapshot = result.rateLimits.codexLimit else {
                    throw CodexClientError.malformedResponse
                }
                guard !targetSnapshot.isExhausted else {
                    throw AccountSwitchError.limitUnavailable
                }

                let previousDesktopProfile = profileStore.desktopProfileID.flatMap { profileID in
                    profileStore.profiles.first(where: { $0.id == profileID })
                }
                try await desktopController.restart(
                    using: profile,
                    previousDesktopProfile: previousDesktopProfile
                )
                profileStore.select(profile.id)
                profileStore.markDesktopProfile(profile.id)
                activeProfile = profileStore.selectedProfile
                applyUsageResult(result, to: profile)
                if reauthenticatedProfileID == profile.id {
                    reauthenticatedProfileID = nil
                }
            } catch {
                switchErrorMessage = error.localizedDescription
            }

            switchingProfileID = nil
        }
    }

    func addAccount() {
        guard loginProfileID == nil, signingOutProfileID == nil else { return }

        do {
            let profile = try profileStore.createIsolatedProfile(named: "")
            startLogin(for: profile, removeProfileOnFailure: true)
        } catch {
            loginErrorMessage = error.localizedDescription
        }
    }

    func signIn(to profileID: UUID) {
        guard loginProfileID == nil,
              signingOutProfileID == nil,
              let profile = profileStore.profiles.first(where: { $0.id == profileID }),
              !profile.usesCurrentCodexHome else {
            return
        }
        startLogin(for: profile, removeProfileOnFailure: false)
    }

    func renameProfile(_ profileID: UUID, to displayName: String) {
        profileStore.rename(profileID, to: displayName)
        activeProfile = profileStore.selectedProfile
        managementErrorMessage = nil
    }

    func removeProfile(_ profileID: UUID) {
        do {
            try profileStore.remove(profileID)
            profileStates.removeValue(forKey: profileID)
            if reauthenticatedProfileID == profileID {
                reauthenticatedProfileID = nil
            }
            activeProfile = profileStore.selectedProfile
            publishActiveState()
            reevaluateSwitchRecommendation()
            managementErrorMessage = nil
        } catch {
            managementErrorMessage = error.localizedDescription
        }
    }

    func signOut(_ profileID: UUID) {
        guard signingOutProfileID == nil,
              switchingProfileID == nil,
              loginProfileID == nil,
              let profile = profileStore.profiles.first(where: { $0.id == profileID }) else {
            return
        }

        signingOutProfileID = profileID
        managementErrorMessage = nil
        Task {
            do {
                if profileStore.desktopProfileID == profileID {
                    try await desktopController.signOut(profile: profile)
                }
                try profileStore.signOut(profileID)
                profileStates[profileID] = ProfileLimitState(errorMessage: "Signed out")
                if reauthenticatedProfileID == profileID {
                    reauthenticatedProfileID = nil
                }
                activeProfile = profileStore.selectedProfile
                publishActiveState()
                reevaluateSwitchRecommendation()
            } catch {
                managementErrorMessage = error.localizedDescription
            }
            signingOutProfileID = nil
        }
    }

    func restartAfterReauthentication(_ profileID: UUID) {
        activateProfileInCodex(profileID, forceRestart: true)
    }

    private func startLogin(
        for profile: AccountProfile,
        removeProfileOnFailure: Bool
    ) {
        loginProfileID = profile.id
        loginErrorMessage = nil
        profileStates[profile.id] = ProfileLimitState(
            errorMessage: "Waiting for ChatGPT sign-in…"
        )

        let client = self.client
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.loginWithChatGPT(for: profile) { url in
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }.value

                let reconciliation = profileStore.reconcileCredentialIdentity(for: profile.id)
                for removedID in reconciliation.removedProfileIDs {
                    profileStates.removeValue(forKey: removedID)
                }
                guard let resolvedProfile = profileStore.profiles.first(where: {
                    $0.id == reconciliation.canonicalProfileID
                }) else {
                    throw CodexClientError.malformedResponse
                }
                activeProfile = profileStore.selectedProfile
                await refreshProfile(resolvedProfile)
                if profileStore.desktopProfileID == resolvedProfile.id {
                    reauthenticatedProfileID = resolvedProfile.id
                }
                loginErrorMessage = nil
            } catch {
                var state = profileStates[profile.id] ?? ProfileLimitState()
                state.errorMessage = error.localizedDescription
                profileStates[profile.id] = state
                loginErrorMessage = error.localizedDescription
                if removeProfileOnFailure,
                   !profileStore.hasCredential(for: profile.id),
                   profileStore.profiles.contains(where: { $0.id == profile.id }) {
                    try? profileStore.remove(profile.id)
                    profileStates.removeValue(forKey: profile.id)
                    activeProfile = profileStore.selectedProfile
                    publishActiveState()
                }
            }

            loginProfileID = nil
        }
    }

    private func refreshProfile(_ profile: AccountProfile) async {
        let client = self.client

        do {
            let result = try await Task.detached(priority: .utility) {
                try client.fetchAccountUsage(for: profile)
            }.value

            guard result.rateLimits.codexLimit != nil else {
                throw CodexClientError.malformedResponse
            }
            applyUsageResult(result, to: profile)
        } catch {
            var state = profileStates[profile.id] ?? ProfileLimitState()
            state.errorMessage = error.localizedDescription
            profileStates[profile.id] = state

            if profileStore.selectedProfileID == profile.id {
                activeProfile = profile
                publishActiveState()
            }
            reevaluateSwitchRecommendation()
        }
    }

    private func applyUsageResult(
        _ result: AccountUsageResult,
        to profile: AccountProfile
    ) {
        guard let codexLimit = result.rateLimits.codexLimit else { return }

        let updateTime = Date()
        let previousState = profileStates[profile.id]
        let resolvedPlanType = codexLimit.planType ?? result.account?.planType
        profileStates[profile.id] = ProfileLimitState(
            snapshot: codexLimit,
            resetCreditCount: result.rateLimits.rateLimitResetCredits?.availableCount ?? 0,
            account: result.account,
            planType: resolvedPlanType,
            errorMessage: nil,
            lastUpdated: updateTime
        )

        let updatedProfile = profileStore.updateIdentity(
            for: profile.id,
            email: result.account?.email,
            planType: resolvedPlanType,
            lastUpdated: updateTime
        )

        if profileStore.selectedProfileID == profile.id {
            activeProfile = updatedProfile ?? profile
            publishActiveState()
        }
        processLimitNotifications(
            profile: updatedProfile ?? profile,
            previousSnapshot: previousState?.snapshot,
            currentSnapshot: codexLimit
        )
        reevaluateSwitchRecommendation()
    }

    private func publishActiveState() {
        let state = profileStates[profileStore.selectedProfileID]
        snapshot = state?.snapshot
        resetCreditCount = state?.resetCreditCount ?? 0
        account = state?.account
        planType = state?.planType ?? activeProfile.planType
        errorMessage = state?.errorMessage
        lastUpdated = state?.lastUpdated
    }

    private func reevaluateSwitchRecommendation() {
        let activeProfileID = profileStore.selectedProfileID
        guard let activeSnapshot = profileStates[activeProfileID]?.snapshot,
              activeSnapshot.isExhausted else {
            switchRecommendation = nil
            recommendationPromptKey = nil
            return
        }

        let candidates = profileStore.profiles.compactMap { profile -> AccountSwitchRecommendation? in
            guard profile.id != activeProfileID,
                  profileStore.hasCredential(for: profile.id),
                  let state = profileStates[profile.id],
                  state.errorMessage == nil,
                  let snapshot = state.snapshot,
                  !snapshot.displayWindows.isEmpty else {
                return nil
            }

            let availableAt: Date
            if snapshot.isExhausted {
                guard let resetDate = snapshot.nextAvailableDate(now: now) else { return nil }
                availableAt = resetDate
            } else {
                availableAt = .distantPast
            }

            return AccountSwitchRecommendation(
                profileID: profile.id,
                availableAt: availableAt,
                usableHeadroom: snapshot.usableHeadroom
            )
        }

        let recommendation = AccountSwitchAdvisor.best(from: candidates, now: now)
        if switchRecommendation != recommendation {
            switchRecommendation = recommendation
        }

        guard let recommendation else {
            recommendationPromptKey = nil
            return
        }

        let promptKey = RecommendationPromptKey(
            activeProfileID: activeProfileID,
            recommendedProfileID: recommendation.profileID,
            isReady: recommendation.isAvailable(at: now)
        )
        guard promptKey != recommendationPromptKey else { return }

        recommendationPromptKey = promptKey
        if settings.autoOpenRecommendations {
            requestHUDPopover(.accounts)
        }

        if promptKey.isReady, settings.notificationsEnabled {
            let profileName = profileStore.profiles
                .first(where: { $0.id == recommendation.profileID })
                .map(notificationProfileName) ?? "Another account"
            notificationService.send(
                identifier: "recommendation-\(activeProfileID)-\(recommendation.profileID)",
                title: "Codex limit exhausted",
                body: "\(profileName) is available now. Open the HUD to switch.",
                destination: .accounts
            )
        }
    }

    private func processLimitNotifications(
        profile: AccountProfile,
        previousSnapshot: RateLimitSnapshot?,
        currentSnapshot: RateLimitSnapshot
    ) {
        guard settings.notificationsEnabled else { return }

        let isActiveProfile = profileStore.selectedProfileID == profile.id
        if isActiveProfile, settings.notifyLowLimit {
            for window in currentSnapshot.displayWindows {
                let key = "\(profile.id)-\(window.windowDurationMins)"
                let remaining = window.remainingPercent
                if remaining > Double(settings.lowLimitThreshold) {
                    notifiedLowLimitKeys.remove(key)
                } else if remaining >= 0.5, !notifiedLowLimitKeys.contains(key) {
                    notifiedLowLimitKeys.insert(key)
                    notificationService.send(
                        identifier: "low-\(key)-\(Int(window.resetsAt ?? 0))",
                        title: "Codex limit is running low",
                        body: "\(window.displayTitle) has \(Int(remaining.rounded()))% remaining.",
                        destination: .limits
                    )
                }
            }
        }

        if isActiveProfile,
           settings.notifyLowLimit,
           previousSnapshot?.isExhausted == false,
           currentSnapshot.isExhausted,
           !hasReadyAlternativeAccount(excluding: profile.id) {
            let exhaustedWindows = currentSnapshot.displayWindows
                .filter(\.isExhausted)
                .map(\.displayTitle)
            let limitName = exhaustedWindows.isEmpty
                ? "The active Codex limit"
                : exhaustedWindows.joined(separator: " and ")
            let resetToken = currentSnapshot.displayWindows
                .compactMap(\.resetsAt)
                .max() ?? Date().timeIntervalSince1970
            notificationService.send(
                identifier: "exhausted-\(profile.id)-\(Int(resetToken))",
                title: "Codex limit exhausted",
                body: "\(limitName) is exhausted. Open Accounts to choose what to use next.",
                destination: .accounts
            )
        }

        if settings.notifyOnReset,
           previousSnapshot?.isExhausted == true,
           !currentSnapshot.isExhausted {
            notificationService.send(
                identifier: "reset-\(profile.id)-\(Int(Date().timeIntervalSince1970))",
                title: "Codex limit restored",
                body: "\(notificationProfileName(profile)) is available again.",
                destination: .accounts
            )
        }
    }

    private func hasReadyAlternativeAccount(excluding activeProfileID: UUID) -> Bool {
        profileStore.profiles.contains { profile in
            guard profile.id != activeProfileID,
                  profileStore.hasCredential(for: profile.id),
                  let state = profileStates[profile.id],
                  state.errorMessage == nil,
                  let snapshot = state.snapshot,
                  !snapshot.displayWindows.isEmpty else {
                return false
            }
            return !snapshot.isExhausted
        }
    }

    private func notificationProfileName(_ profile: AccountProfile) -> String {
        if profile.displayName != AccountProfile.current.displayName,
           !profile.displayName.hasPrefix("Account ") {
            return profile.displayName
        }
        return settings.displayEmail(profile.email) ?? profile.displayName
    }
}
