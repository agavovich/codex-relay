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
            try Data("self-test".utf8).write(
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
        } catch {
            failures.append("account management self-test failed: \(error.localizedDescription)")
        }

        try? fileManager.removeItem(at: testRoot)

        let suiteName = "local.codex.limit-hud.self-test.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            let settings = AppSettings(defaults: defaults)
            expect(settings.compactHUD, "compact HUD should be enabled by default")
            settings.compactHUD = false
            settings.maskEmails = true
            expect(
                settings.displayEmail("person@example.com") == "p•••@example.com",
                "email masking is wrong"
            )
            expect(
                !AppSettings(defaults: defaults).compactHUD,
                "HUD layout preference was not persisted"
            )
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            failures.append("settings self-test suite could not be created")
        }

        return failures
    }
}
