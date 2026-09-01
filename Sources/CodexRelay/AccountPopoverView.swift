import SwiftUI

private struct PendingSwitch {
    let profile: AccountProfile
    let activity: CodexActivityState
    let forceRestart: Bool
}

private enum AccountPopoverAlert: Identifiable {
    case switchAccount(PendingSwitch)
    case remove(AccountProfile)

    var id: String {
        switch self {
        case .switchAccount(let pending): return "switch-\(pending.profile.id)"
        case .remove(let profile): return "remove-\(profile.id)"
        }
    }
}

struct AccountPopoverView: View {
    @ObservedObject var store: LimitStore
    let onSelect: () -> Void

    @State private var showingSettings = false
    @State private var editingProfileID: UUID?
    @State private var editedName = ""
    @State private var pendingAlert: AccountPopoverAlert?

    var body: some View {
        VStack(spacing: 11) {
            header
            Divider()

            if showingSettings {
                settingsContent
            } else {
                accountsContent
            }
        }
        .padding(13)
        .frame(width: 360)
        .alert(item: $pendingAlert, content: alert)
    }

    private var header: some View {
        HStack {
            if showingSettings {
                Button {
                    showingSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to accounts")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(showingSettings ? "Settings" : "Accounts")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(showingSettings
                     ? "Privacy, alerts, and HUD behavior"
                     : "Switch the Codex account and its limits")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showingSettings {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button(action: store.refresh) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh all accounts")
                .disabled(store.isRefreshing)

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
    }

    private var accountsContent: some View {
        VStack(spacing: 11) {
            if let recommendation = store.switchRecommendation,
               let profile = store.profile(for: recommendation.profileID) {
                recommendationBanner(recommendation, profile: profile)
                Divider()
            }

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(store.profiles) { profile in
                        accountCard(profile)
                    }
                }
            }
            .frame(maxHeight: 340)

            Divider()

            Button(action: store.addAccount) {
                HStack(spacing: 7) {
                    if store.isAddingAccount {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text(store.isAddingAccount ? "Waiting for sign-in…" : "Add Account…")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(store.isAddingAccount || store.isSwitchingCodex)

            errorMessages

            Text("Accounts share your local projects, history, and settings.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                settingsSection("PRIVACY") {
                    Toggle("Mask email addresses", isOn: $store.settings.maskEmails)
                }

                settingsSection("NOTIFICATIONS") {
                    Toggle("Enable notifications", isOn: Binding(
                        get: { store.settings.notificationsEnabled },
                        set: store.setNotificationsEnabled
                    ))

                    Toggle("Low-limit alert", isOn: $store.settings.notifyLowLimit)
                        .disabled(!store.settings.notificationsEnabled)

                    Picker("Alert at", selection: $store.settings.lowLimitThreshold) {
                        ForEach(AppSettings.lowLimitThresholds, id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                    .disabled(!store.settings.notificationsEnabled || !store.settings.notifyLowLimit)

                    Toggle("Notify when a limit resets", isOn: $store.settings.notifyOnReset)
                        .disabled(!store.settings.notificationsEnabled)
                }

                settingsSection("BEHAVIOR") {
                    Toggle("Use compact HUD", isOn: $store.settings.compactHUD)

                    Text(store.settings.compactHUD
                         ? "Shows the preferred limit as a ring. Click it to open accounts."
                         : "Shows the plan and every active limit at all times.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker("Refresh every", selection: $store.settings.refreshInterval) {
                        ForEach(AppSettings.refreshIntervals, id: \.self) { interval in
                            Text(refreshIntervalTitle(interval)).tag(interval)
                        }
                    }

                    Toggle("Open suggestions automatically", isOn: $store.settings.autoOpenRecommendations)
                    Toggle("Show HUD only while Codex runs", isOn: $store.settings.showOnlyWhileCodexRuns)
                    Toggle("Launch at Login", isOn: Binding(
                        get: { store.settings.launchAtLogin },
                        set: store.settings.setLaunchAtLogin
                    ))
                }

                settingsSection("SWITCHING SAFETY") {
                    Toggle("Detect visible active tasks", isOn: Binding(
                        get: { store.settings.activeTaskDetection },
                        set: store.setActiveTaskDetection
                    ))

                    Text("Uses macOS Accessibility to look for Codex’s visible Stop button. "
                         + "Without permission, switching keeps the conservative warning.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(
                        store.settings.accessibilityGranted
                            ? "Accessibility access granted"
                            : "Accessibility access not granted",
                        systemImage: store.settings.accessibilityGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle"
                    )
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(store.settings.accessibilityGranted ? Color.mint : Color.secondary)
                }

                if let error = store.settings.settingsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxHeight: 430)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8, content: content)
                .font(.system(size: 10.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountCard(_ profile: AccountProfile) -> some View {
        let state = store.profileState(for: profile.id)
        let isSelected = store.activeProfile.id == profile.id
        let isDesktopActive = store.isActiveInCodex(profile.id)
        let isSigningIn = store.loginProfileID == profile.id
        let isSwitching = store.switchingProfileID == profile.id
        let needsSignIn = !store.hasCredential(for: profile.id)
        let windows = state?.snapshot?.displayWindows ?? []

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                accountAvatar(profile, selected: isSelected)
                    .contentShape(Circle())
                    .onTapGesture {
                        guard editingProfileID == nil else { return }
                        select(profile)
                    }

                if editingProfileID == profile.id {
                    TextField("Account name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5))
                        .onSubmit { finishRename(profile) }

                    Button { finishRename(profile) } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)

                    Button { editingProfileID = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .font(.system(size: 10.8, weight: .semibold))
                            .lineLimit(1)

                        if let email = store.settings.displayEmail(profile.email) {
                            Text(email)
                                .font(.system(size: 8.8))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(profile) }

                    Spacer(minLength: 3)

                    if let plan = state?.planType ?? profile.planType {
                        badge(plan.uppercased(), color: .secondary)
                    }
                    if isDesktopActive {
                        badge("ACTIVE", color: .mint)
                    }

                    accountMenu(profile, isDesktopActive: isDesktopActive)
                }
            }

            if isSigningIn || isSwitching || needsSignIn || state?.account == nil {
                accountActionState(
                    profile: profile,
                    isSigningIn: isSigningIn,
                    isSwitching: isSwitching,
                    needsSignIn: needsSignIn,
                    error: state?.errorMessage
                )
            } else if !windows.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        AccountWindowCell(window: window, now: store.now)
                    }
                }

                accountAvailability(
                    state?.snapshot,
                    resetCreditCount: state?.resetCreditCount ?? 0
                )
            } else {
                Text(state?.errorMessage ?? "No limits reported")
                    .font(.system(size: 9.5))
                    .foregroundStyle(state?.errorMessage == nil ? Color.secondary : Color.red)
            }

            if store.reauthenticatedProfileID == profile.id {
                HStack(spacing: 5) {
                    Text("New login is ready")
                        .font(.system(size: 9.2))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart to Apply") {
                        requestSwitch(profile, forceRestart: true)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        }
    }

    private func accountAvatar(_ profile: AccountProfile, selected: Bool) -> some View {
        ZStack {
            Circle().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
            Image(systemName: profile.isPrimary ? "person.fill" : "person.crop.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .frame(width: 27, height: 27)
    }

    private func accountMenu(_ profile: AccountProfile, isDesktopActive: Bool) -> some View {
        Menu {
            Button("Rename…") { beginRename(profile) }
            Button("Sign In Again…") { store.signIn(to: profile.id) }

            Divider()

            Button("Remove Account…", role: .destructive) {
                pendingAlert = .remove(profile)
            }
            .disabled(profile.isPrimary || isDesktopActive)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 17, height: 17)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func accountActionState(
        profile: AccountProfile,
        isSigningIn: Bool,
        isSwitching: Bool,
        needsSignIn: Bool,
        error: String?
    ) -> some View {
        HStack(spacing: 6) {
            if isSigningIn || isSwitching {
                ProgressView().controlSize(.small)
            }

            Text(accountActionText(
                isSigningIn: isSigningIn,
                isSwitching: isSwitching,
                needsSignIn: needsSignIn,
                error: error
            ))
                .font(.system(size: 9.5))
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
                .lineLimit(2)

            Spacer()

            if !isSigningIn, !isSwitching, needsSignIn {
                Button("Sign In") { store.signIn(to: profile.id) }
                    .font(.system(size: 9.2, weight: .semibold))
                    .buttonStyle(.borderless)
            }
        }
    }

    private func accountActionText(
        isSigningIn: Bool,
        isSwitching: Bool,
        needsSignIn: Bool,
        error: String?
    ) -> String {
        if isSwitching { return "Restarting Codex…" }
        if isSigningIn { return "Complete sign-in in your browser" }
        if needsSignIn { return "Sign in once to enable this account" }
        return error ?? "Loading limits…"
    }

    private func accountAvailability(
        _ snapshot: RateLimitSnapshot?,
        resetCreditCount: Int
    ) -> some View {
        let exhausted = snapshot?.isExhausted == true
        let resetDate = snapshot?.nextAvailableDate(now: store.now)

        return HStack(spacing: 4) {
            Circle()
                .fill(exhausted ? Color.red : Color.mint)
                .frame(width: 4.5, height: 4.5)

            Text(availabilityText(exhausted: exhausted, resetDate: resetDate))
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(exhausted ? .red : .secondary)

            Spacer(minLength: 6)

            if resetCreditCount > 0 {
                Text(resetCreditText(resetCreditCount))
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.mint)
                    .accessibilityLabel(
                        "\(resetCreditCount) free rate limit "
                            + (resetCreditCount == 1 ? "reset" : "resets")
                            + " available"
                    )
            }
        }
    }

    private func resetCreditText(_ count: Int) -> String {
        "↻\(count) FREE " + (count == 1 ? "RESET" : "RESETS")
    }

    private func availabilityText(exhausted: Bool, resetDate: Date?) -> String {
        guard exhausted else { return "READY" }
        guard let resetDate else { return "LIMITED" }
        let countdown = RateLimitCountdown.text(until: resetDate, now: store.now)
        return countdown == "now" ? "RESET DUE NOW" : "LIMITED · RESET IN \(countdown.uppercased())"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 7.2, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.11)))
    }

    private var errorMessages: some View {
        VStack(spacing: 5) {
            ForEach([
                store.loginErrorMessage,
                store.switchErrorMessage,
                store.managementErrorMessage
            ].compactMap { $0 }, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func recommendationBanner(
        _ recommendation: AccountSwitchRecommendation,
        profile: AccountProfile
    ) -> some View {
        let isReady = recommendation.isAvailable(at: store.now)
        let tint: Color = isReady ? .mint : .orange

        return HStack(spacing: 9) {
            Image(systemName: isReady ? "bolt.fill" : "clock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 19)

            VStack(alignment: .leading, spacing: 2) {
                Text(isReady ? "Best account available now" : "Next account resets first")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                Text(recommendationDetail(recommendation, profile: profile))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isReady {
                Button("Switch") { select(profile) }
                    .font(.system(size: 9.5, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isSwitchingCodex || store.isAddingAccount)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10))
        }
    }

    private func recommendationDetail(
        _ recommendation: AccountSwitchRecommendation,
        profile: AccountProfile
    ) -> String {
        let name = profileLabel(profile)
        guard !recommendation.isAvailable(at: store.now) else { return name }
        let countdown = RateLimitCountdown.text(until: recommendation.availableAt, now: store.now)
        return "\(name) · ready in \(countdown)"
    }

    private func profileLabel(_ profile: AccountProfile) -> String {
        if !profile.displayName.hasPrefix("Account "), profile.displayName != "Primary" {
            return profile.displayName
        }
        return store.settings.displayEmail(profile.email) ?? profile.displayName
    }

    private func beginRename(_ profile: AccountProfile) {
        editedName = profile.displayName
        editingProfileID = profile.id
    }

    private func finishRename(_ profile: AccountProfile) {
        store.renameProfile(profile.id, to: editedName)
        editingProfileID = nil
    }

    private func select(_ profile: AccountProfile) {
        if store.isActiveInCodex(profile.id), store.isCodexRunning {
            onSelect()
            return
        }
        if !store.hasCredential(for: profile.id) {
            store.signIn(to: profile.id)
            return
        }
        if store.isCodexRunning {
            requestSwitch(profile, forceRestart: false)
        } else {
            onSelect()
            store.activateProfileInCodex(profile.id)
        }
    }

    private func requestSwitch(_ profile: AccountProfile, forceRestart: Bool) {
        Task {
            let activity = await store.detectCodexActivity()
            pendingAlert = .switchAccount(PendingSwitch(
                profile: profile,
                activity: activity,
                forceRestart: forceRestart
            ))
        }
    }

    private func alert(_ alert: AccountPopoverAlert) -> Alert {
        switch alert {
        case .switchAccount(let pending):
            return Alert(
                title: Text(pending.activity == .active
                            ? "Codex is working"
                            : "Switch Codex account?"),
                message: Text(switchMessage(pending)),
                primaryButton: .default(Text("Switch & Restart")) {
                    onSelect()
                    store.activateProfileInCodex(
                        pending.profile.id,
                        forceRestart: pending.forceRestart
                    )
                },
                secondaryButton: .cancel()
            )

        case .remove(let profile):
            return Alert(
                title: Text("Remove \(profile.displayName)?"),
                message: Text("Its local credential vault will be permanently deleted. "
                              + "Shared Codex projects and history will remain intact."),
                primaryButton: .destructive(Text("Remove")) {
                    store.removeProfile(profile.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func switchMessage(_ pending: PendingSwitch) -> String {
        let account = profileLabel(pending.profile)
        switch pending.activity {
        case .active:
            return "A visible Codex task is currently running. Switching to \(account) "
                + "will interrupt it, but its history will remain available."
        case .idle:
            return "Codex will close and reopen as \(account). Local projects and history will remain available."
        case .unknown:
            return "Codex activity could not be verified. Switching to \(account) may interrupt "
                + "a running task, but its history will remain available."
        }
    }

    private func refreshIntervalTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 30: return "30 seconds"
        case 60: return "1 minute"
        case 120: return "2 minutes"
        default: return "5 minutes"
        }
    }
}

private struct AccountWindowCell: View {
    let window: RateLimitWindow
    let now: Date

    private var remaining: Double { window.remainingPercent }

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
                    .font(.system(size: 7.2, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
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
            .frame(height: 3)

            Text("↻ \(RateLimitCountdown.text(until: window.resetsAt, now: now))")
                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
    }
}
