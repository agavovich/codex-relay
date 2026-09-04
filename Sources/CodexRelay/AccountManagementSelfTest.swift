import Foundation

@MainActor
enum AccountManagementSelfTest {
    static func run() -> [String] {
        var failures: [String] = []
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codex-relay-self-test-\(UUID().uuidString)", isDirectory: true)

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        expect(
            HUDMetrics.expandedBaseWidth(windowCount: 1) < HUDMetrics.baseWidth,
            "single-window HUD was not narrowed"
        )
        expect(
            HUDMetrics.expandedBaseWidth(windowCount: 2) == HUDMetrics.baseWidth,
            "two-window HUD width changed"
        )
        expect(
            HUDMetrics.expandedBaseWidth(windowCount: 1) == 220,
            "single-window HUD sections are not balanced"
        )

        do {
            let primaryVault = testRoot
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(AccountProfile.current.id.uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: primaryVault,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try credentialData(
                accountID: "self-test-primary",
                refreshedAt: "2026-01-01T00:00:00Z",
                refreshToken: "old-refresh"
            ).write(
                to: primaryVault.appendingPathComponent("auth.json"),
                options: .atomic
            )

            let store = AccountProfileStore(storageDirectory: testRoot, fileManager: fileManager)
            store.rename(AccountProfile.current.id, to: "Work")
            expect(store.selectedProfile.displayName == "Work", "primary profile was not renamed")

            let backup = try store.createIsolatedProfile(named: "Backup")
            expect(store.profiles.contains(where: { $0.id == backup.id }), "account was not created")
            try store.remove(backup.id)
            expect(!store.profiles.contains(where: { $0.id == backup.id }), "account was not removed")
            expect(
                !fileManager.fileExists(atPath: backup.codexHomePath ?? ""),
                "removed account vault still exists"
            )

            do {
                try store.remove(AccountProfile.current.id)
                failures.append("primary profile removal was allowed")
            } catch AccountProfileStoreError.cannotRemovePrimary {
                // Expected.
            } catch {
                failures.append("primary profile removal returned the wrong error")
            }

            let active = try store.createIsolatedProfile(named: "Active")
            store.markDesktopProfile(active.id)
            do {
                try store.remove(active.id)
                failures.append("active profile removal was allowed")
            } catch AccountProfileStoreError.cannotRemoveActive {
                // Expected.
            } catch {
                failures.append("active profile removal returned the wrong error")
            }

            let duplicate = try store.createIsolatedProfile(named: "Duplicate")
            let duplicateCredentialURL = URL(
                fileURLWithPath: duplicate.codexHomePath!,
                isDirectory: true
            ).appendingPathComponent("auth.json")
            try credentialData(
                accountID: "self-test-primary",
                refreshedAt: "2026-02-01T00:00:00Z",
                refreshToken: "new-refresh"
            ).write(to: duplicateCredentialURL, options: .atomic)
            _ = store.updateIdentity(
                for: duplicate.id,
                email: "person@example.com",
                planType: "prolite",
                lastUpdated: Date()
            )
            store.select(duplicate.id)
            store.markDesktopProfile(duplicate.id)

            let reconciliation = store.reconcileCredentialIdentity(for: duplicate.id)
            expect(
                reconciliation.canonicalProfileID == AccountProfile.current.id,
                "duplicate account did not merge into primary profile"
            )
            expect(
                reconciliation.removedProfileIDs == [duplicate.id],
                "duplicate reconciliation reported the wrong removed profile"
            )
            expect(
                !store.profiles.contains(where: { $0.id == duplicate.id }),
                "duplicate account remained in the profile list"
            )
            expect(
                store.selectedProfileID == AccountProfile.current.id,
                "selected duplicate was not remapped to primary"
            )
            expect(
                store.desktopProfileID == AccountProfile.current.id,
                "desktop duplicate was not remapped to primary"
            )
            let mergedCredential = try Data(
                contentsOf: store.credentialURL(for: AccountProfile.current.id)!
            )
            expect(
                String(decoding: mergedCredential, as: UTF8.self).contains("new-refresh"),
                "newest credential did not survive duplicate merge"
            )
            expect(
                store.selectedProfile.planType == "prolite",
                "newest account metadata did not survive duplicate merge"
            )

            try store.signOut(AccountProfile.current.id)
            expect(
                !store.hasCredential(for: AccountProfile.current.id),
                "sign out left the account credential in its vault"
            )
            expect(
                store.profiles.contains(where: { $0.id == AccountProfile.current.id }),
                "sign out removed the profile itself"
            )
            expect(store.desktopProfileID == nil, "sign out kept a desktop account marker")
        } catch {
            failures.append("account management self-test failed: \(error.localizedDescription)")
        }

        try? fileManager.removeItem(at: testRoot)

        let suiteName = "local.codex.limit-hud.self-test.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            let settings = AppSettings(defaults: defaults)
            expect(settings.hudStyle == .compact, "compact HUD should be enabled by default")
            expect(settings.hudPlacement == .dock, "HUD should attach to the Dock by default")
            settings.setHUDStyle(.expanded)
            settings.setHUDPlacement(.free)
            settings.saveDetachedHUDOrigin(CGPoint(x: 120, y: 80))
            settings.saveEdgeHUDCenterY(440)
            settings.maskEmails = true
            expect(
                settings.displayEmail("person@example.com") == "p•••@example.com",
                "email masking is wrong"
            )
            expect(
                AppSettings(defaults: defaults).hudStyle == .expanded,
                "HUD layout preference was not persisted"
            )
            let restoredSettings = AppSettings(defaults: defaults)
            expect(
                restoredSettings.hudPlacement == .free,
                "HUD attachment preference was not persisted"
            )
            expect(
                restoredSettings.detachedHUDOrigin == CGPoint(x: 120, y: 80),
                "detached HUD position was not persisted"
            )
            expect(
                restoredSettings.edgeHUDCenterY == 440,
                "right-edge HUD position was not persisted"
            )

            restoredSettings.setHUDStyle(.edgeStrip)
            expect(
                restoredSettings.hudPlacement == .rightEdge,
                "Edge Strip should force right-edge placement"
            )
            restoredSettings.setHUDStyle(.compact)
            expect(
                restoredSettings.hudPlacement == .free,
                "leaving Edge Strip should restore the previous placement"
            )
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            failures.append("settings self-test suite could not be created")
        }

        expect(CodexPlan.displayName("prolite") == "PRO", "prolite plan label was exposed")
        expect(CodexPlan.displayName("plus") == "PLUS", "plus plan label is wrong")

        return failures
    }

    private static func credentialData(
        accountID: String,
        refreshedAt: String,
        refreshToken: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": refreshedAt,
            "tokens": [
                "account_id": accountID,
                "access_token": "self-test-access",
                "id_token": "self-test-id",
                "refresh_token": refreshToken
            ]
        ], options: [.sortedKeys])
    }
}
