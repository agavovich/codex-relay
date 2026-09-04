import Foundation

enum AccountProfileStoreError: LocalizedError {
    case cannotRemovePrimary
    case cannotRemoveActive
    case invalidProfileDirectory

    var errorDescription: String? {
        switch self {
        case .cannotRemovePrimary:
            return "The primary account cannot be removed."
        case .cannotRemoveActive:
            return "Switch Codex to another account before removing this profile."
        case .invalidProfileDirectory:
            return "The profile directory is outside the protected account vault."
        }
    }
}

struct AccountProfile: Codable, Equatable, Identifiable {
    static let current = AccountProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayName: "Primary",
        codexHomePath: nil,
        accountID: nil,
        email: nil,
        planType: nil,
        lastUpdated: nil,
        createdAt: Date(timeIntervalSince1970: 0)
    )

    let id: UUID
    var displayName: String
    var codexHomePath: String?
    var accountID: String?
    var email: String?
    var planType: String?
    var lastUpdated: Date?
    let createdAt: Date

    var usesCurrentCodexHome: Bool {
        codexHomePath == nil
    }

    var isPrimary: Bool {
        id == Self.current.id
    }
}

@MainActor
final class AccountProfileStore: ObservableObject {
    struct ReconciliationResult: Equatable {
        let canonicalProfileID: UUID
        let removedProfileIDs: Set<UUID>
    }

    @Published private(set) var profiles: [AccountProfile]
    @Published private(set) var selectedProfileID: UUID
    @Published private(set) var persistenceError: String?

    private struct PersistedState: Codable {
        let version: Int
        var profiles: [AccountProfile]
        var selectedProfileID: UUID
        var desktopProfileID: UUID?

        init(
            version: Int,
            profiles: [AccountProfile],
            selectedProfileID: UUID,
            desktopProfileID: UUID?
        ) {
            self.version = version
            self.profiles = profiles
            self.selectedProfileID = selectedProfileID
            self.desktopProfileID = desktopProfileID
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case profiles
            case selectedProfileID
            case desktopProfileID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            profiles = try container.decode([AccountProfile].self, forKey: .profiles)
            selectedProfileID = try container.decode(UUID.self, forKey: .selectedProfileID)
            desktopProfileID = try container.decodeIfPresent(UUID.self, forKey: .desktopProfileID)
        }
    }

    private let fileManager: FileManager
    private let storageDirectory: URL?
    private let stateURL: URL?
    private(set) var desktopProfileID: UUID?

    init(storageDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let resolvedDirectory: URL?
        let legacyDirectoryForPathMigration: URL?
        if let storageDirectory {
            resolvedDirectory = storageDirectory
            legacyDirectoryForPathMigration = nil
        } else {
            let applicationSupport = try? fileManager
                .url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            let relayDirectory = applicationSupport?
                .appendingPathComponent("Codex Relay", isDirectory: true)
            let legacyDirectory = applicationSupport?
                .appendingPathComponent("Codex Limit HUD", isDirectory: true)
            legacyDirectoryForPathMigration = legacyDirectory

            if let relayDirectory,
               let legacyDirectory,
               !fileManager.fileExists(atPath: relayDirectory.path),
               fileManager.fileExists(atPath: legacyDirectory.path) {
                do {
                    try fileManager.moveItem(at: legacyDirectory, to: relayDirectory)
                    resolvedDirectory = relayDirectory
                } catch {
                    // Preserve access to existing profiles if migration cannot run.
                    resolvedDirectory = legacyDirectory
                }
            } else {
                resolvedDirectory = relayDirectory
            }
        }

        self.storageDirectory = resolvedDirectory
        self.stateURL = resolvedDirectory?.appendingPathComponent("profiles.json")

        if let stateURL,
           let data = try? Data(contentsOf: stateURL),
           let state = try? Self.decoder.decode(PersistedState.self, from: data),
           !state.profiles.isEmpty {
            let loadedProfiles = Self.migratingProfilePaths(
                state.profiles,
                from: legacyDirectoryForPathMigration,
                to: resolvedDirectory
            )
            profiles = loadedProfiles
            selectedProfileID = loadedProfiles.contains(where: { $0.id == state.selectedProfileID })
                ? state.selectedProfileID
                : loadedProfiles[0].id
            desktopProfileID = state.desktopProfileID
        } else {
            profiles = [.current]
            selectedProfileID = AccountProfile.current.id
            desktopProfileID = nil
        }

        migratePrimaryCredentialVault()
        reconcileAllCredentialIdentities()
        persist()
    }

    private static func migratingProfilePaths(
        _ profiles: [AccountProfile],
        from legacyDirectory: URL?,
        to storageDirectory: URL?
    ) -> [AccountProfile] {
        guard let legacyDirectory,
              let storageDirectory,
              legacyDirectory.standardizedFileURL != storageDirectory.standardizedFileURL else {
            return profiles
        }

        let legacyPrefix = legacyDirectory.standardizedFileURL.path + "/"
        let replacementPrefix = storageDirectory.standardizedFileURL.path + "/"
        return profiles.map { profile in
            guard let path = profile.codexHomePath,
                  path.hasPrefix(legacyPrefix) else { return profile }

            var migrated = profile
            migrated.codexHomePath = replacementPrefix + path.dropFirst(legacyPrefix.count)
            return migrated
        }
    }

    var selectedProfile: AccountProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
    }

    func select(_ profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        selectedProfileID = profileID
        persist()
    }

    func markDesktopProfile(_ profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        desktopProfileID = profileID
        persist()
    }

    func clearDesktopProfile(ifMatches profileID: UUID? = nil) {
        if let profileID, desktopProfileID != profileID { return }
        desktopProfileID = nil
        persist()
    }

    func rename(_ profileID: UUID, to displayName: String) {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].displayName = trimmedName
        persist()
    }

    func remove(_ profileID: UUID) throws {
        guard profileID != AccountProfile.current.id else {
            throw AccountProfileStoreError.cannotRemovePrimary
        }
        guard desktopProfileID != profileID else {
            throw AccountProfileStoreError.cannotRemoveActive
        }
        guard let storageDirectory,
              let profile = profiles.first(where: { $0.id == profileID }),
              let profilePath = profile.codexHomePath else {
            throw AccountProfileStoreError.invalidProfileDirectory
        }

        let vaultRoot = storageDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .standardizedFileURL
        let profileURL = URL(fileURLWithPath: profilePath, isDirectory: true)
            .standardizedFileURL
        guard profileURL.deletingLastPathComponent() == vaultRoot,
              profileURL.lastPathComponent == profileID.uuidString else {
            throw AccountProfileStoreError.invalidProfileDirectory
        }

        if fileManager.fileExists(atPath: profileURL.path) {
            try fileManager.removeItem(at: profileURL)
        }
        profiles.removeAll(where: { $0.id == profileID })
        if selectedProfileID == profileID {
            selectedProfileID = AccountProfile.current.id
        }
        persist()
    }

    func credentialURL(for profileID: UUID) -> URL? {
        guard let path = profiles.first(where: { $0.id == profileID })?.codexHomePath else {
            return nil
        }
        return URL(fileURLWithPath: path).appendingPathComponent("auth.json")
    }

    func hasCredential(for profileID: UUID) -> Bool {
        guard let url = credentialURL(for: profileID) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    @discardableResult
    func reconcileCredentialIdentity(for profileID: UUID) -> ReconciliationResult {
        guard profiles.contains(where: { $0.id == profileID }) else {
            return ReconciliationResult(
                canonicalProfileID: profileID,
                removedProfileIDs: []
            )
        }

        refreshStoredAccountIDs()
        let result = mergeDuplicates(containing: profileID)
        persist()
        return result
    }

    func signOut(_ profileID: UUID) throws {
        guard let credentialURL = credentialURL(for: profileID),
              let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AccountProfileStoreError.invalidProfileDirectory
        }

        if fileManager.fileExists(atPath: credentialURL.path) {
            try fileManager.removeItem(at: credentialURL)
        }
        profiles[index].accountID = nil
        profiles[index].planType = nil
        profiles[index].lastUpdated = nil
        if desktopProfileID == profileID {
            desktopProfileID = nil
        }
        persist()
    }

    @discardableResult
    func updateIdentity(
        for profileID: UUID,
        email: String?,
        planType: String?,
        lastUpdated: Date
    ) -> AccountProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return nil
        }

        profiles[index].email = email
        profiles[index].planType = planType
        profiles[index].lastUpdated = lastUpdated
        persist()
        return profiles[index]
    }

    func createIsolatedProfile(named displayName: String) throws -> AccountProfile {
        guard let storageDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        let id = UUID()
        let codexHome = storageDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)

        try fileManager.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let configURL = codexHome.appendingPathComponent("config.toml")
        let config = "cli_auth_credentials_store = \"file\"\n"
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = AccountProfile(
            id: id,
            displayName: trimmedName.isEmpty ? "Account \(profiles.count + 1)" : trimmedName,
            codexHomePath: codexHome.path,
            accountID: nil,
            email: nil,
            planType: nil,
            lastUpdated: nil,
            createdAt: Date()
        )

        profiles.append(profile)
        persist()
        return profile
    }

    private func reconcileAllCredentialIdentities() {
        refreshStoredAccountIDs()
        let duplicateAccountIDs = Dictionary(grouping: profiles.compactMap { profile in
            profile.accountID.map { ($0, profile.id) }
        }, by: \.0)
            .filter { $0.value.count > 1 }
            .keys

        for accountID in duplicateAccountIDs {
            guard let profileID = profiles.first(where: { $0.accountID == accountID })?.id else {
                continue
            }
            _ = mergeDuplicates(containing: profileID)
        }
    }

    private func refreshStoredAccountIDs() {
        for index in profiles.indices {
            guard let credentialURL = credentialURL(for: profiles[index].id),
                  let accountID = credentialMetadata(at: credentialURL)?.accountID else {
                continue
            }
            profiles[index].accountID = accountID
        }
    }

    private func mergeDuplicates(containing profileID: UUID) -> ReconciliationResult {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              let accountID = profile.accountID else {
            return ReconciliationResult(
                canonicalProfileID: profileID,
                removedProfileIDs: []
            )
        }

        let duplicates = profiles.filter { $0.accountID == accountID }
        guard duplicates.count > 1 else {
            return ReconciliationResult(
                canonicalProfileID: profileID,
                removedProfileIDs: []
            )
        }

        let canonical = duplicates.first(where: \.isPrimary)
            ?? duplicates.min(by: { $0.createdAt < $1.createdAt })!
        let removed = Set(duplicates.map(\.id).filter { $0 != canonical.id })

        let freshestIdentity = duplicates.max { lhs, rhs in
            (lhs.lastUpdated ?? .distantPast) < (rhs.lastUpdated ?? .distantPast)
        } ?? canonical
        let freshestCredential = duplicates.compactMap { candidate -> (AccountProfile, CredentialMetadata)? in
            guard let url = credentialURL(for: candidate.id),
                  let metadata = credentialMetadata(at: url) else { return nil }
            return (candidate, metadata)
        }.max { lhs, rhs in
            lhs.1.refreshedAt < rhs.1.refreshedAt
        }

        if let source = freshestCredential?.0,
           source.id != canonical.id,
           let sourceURL = credentialURL(for: source.id),
           let destinationURL = credentialURL(for: canonical.id) {
            try? copyCredential(from: sourceURL, to: destinationURL)
        }

        if let canonicalIndex = profiles.firstIndex(where: { $0.id == canonical.id }) {
            profiles[canonicalIndex].accountID = accountID
            profiles[canonicalIndex].email = freshestIdentity.email ?? canonical.email
            profiles[canonicalIndex].planType = freshestIdentity.planType ?? canonical.planType
            profiles[canonicalIndex].lastUpdated = [
                freshestIdentity.lastUpdated,
                canonical.lastUpdated
            ].compactMap { $0 }.max()
        }

        if removed.contains(selectedProfileID) {
            selectedProfileID = canonical.id
        }
        if let desktopProfileID, removed.contains(desktopProfileID) {
            self.desktopProfileID = canonical.id
        }

        for duplicate in duplicates where removed.contains(duplicate.id) {
            if let path = duplicate.codexHomePath {
                try? archiveMergedProfileDirectory(
                    URL(fileURLWithPath: path, isDirectory: true),
                    profileID: duplicate.id
                )
            }
        }
        profiles.removeAll { removed.contains($0.id) }

        return ReconciliationResult(
            canonicalProfileID: canonical.id,
            removedProfileIDs: removed
        )
    }

    private func archiveMergedProfileDirectory(_ sourceURL: URL, profileID: UUID) throws {
        guard let storageDirectory, fileManager.fileExists(atPath: sourceURL.path) else { return }
        let archiveRoot = storageDirectory
            .appendingPathComponent("Merged Profiles", isDirectory: true)
        try fileManager.createDirectory(
            at: archiveRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: archiveRoot.path
        )

        let destinationURL = archiveRoot
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destinationURL.path) else { return }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private struct CredentialMetadata {
        let accountID: String
        let refreshedAt: Date
    }

    private func credentialMetadata(at url: URL) -> CredentialMetadata? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String,
              !accountID.isEmpty else {
            return nil
        }

        let refreshedAt = (object["last_refresh"] as? String)
            .flatMap(Self.iso8601.date(from:))
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            ?? .distantPast
        return CredentialMetadata(accountID: accountID, refreshedAt: refreshedAt)
    }

    private func migratePrimaryCredentialVault() {
        guard let storageDirectory,
              let index = profiles.firstIndex(where: { $0.id == AccountProfile.current.id }) else {
            return
        }

        do {
            let vaultURL = try prepareProfileDirectory(
                storageDirectory: storageDirectory,
                profileID: AccountProfile.current.id
            )
            let vaultCredentialURL = vaultURL.appendingPathComponent("auth.json")

            if !fileManager.fileExists(atPath: vaultCredentialURL.path) {
                let sharedCredentialURL = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex", isDirectory: true)
                    .appendingPathComponent("auth.json")

                if fileManager.fileExists(atPath: sharedCredentialURL.path) {
                    try copyCredential(from: sharedCredentialURL, to: vaultCredentialURL)
                }
            }

            profiles[index].codexHomePath = vaultURL.path
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func prepareProfileDirectory(
        storageDirectory: URL,
        profileID: UUID
    ) throws -> URL {
        let profilesURL = storageDirectory.appendingPathComponent("Profiles", isDirectory: true)
        try fileManager.createDirectory(
            at: profilesURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: profilesURL.path
        )

        let profileURL = profilesURL.appendingPathComponent(profileID.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: profileURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: profileURL.path
        )

        let configURL = profileURL.appendingPathComponent("config.toml")
        if !fileManager.fileExists(atPath: configURL.path) {
            let config = "cli_auth_credentials_store = \"file\"\n"
            try Data(config.utf8).write(to: configURL, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configURL.path
        )
        return profileURL
    }

    private func copyCredential(from sourceURL: URL, to destinationURL: URL) throws {
        let credential = try Data(contentsOf: sourceURL)
        try credential.write(to: destinationURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    private func persist() {
        guard let storageDirectory, let stateURL else { return }

        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let state = PersistedState(
                version: 2,
                profiles: profiles,
                selectedProfileID: selectedProfileID,
                desktopProfileID: desktopProfileID
            )
            let data = try Self.encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let iso8601 = ISO8601DateFormatter()
}
