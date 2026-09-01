import AppKit
import Foundation

enum CodexDesktopError: LocalizedError {
    case applicationNotFound
    case profileHomeMissing(String)
    case credentialMissing(String)
    case credentialSwapFailed(String)
    case quitRejected
    case quitTimedOut
    case relaunchFailed(String)
    case relaunchTimedOut

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return "The Codex desktop app could not be found."
        case .profileHomeMissing(let path):
            return "The selected Codex profile is missing: \(path)"
        case .credentialMissing(let path):
            return "This account needs to be signed in again before switching: \(path)"
        case .credentialSwapFailed(let message):
            return "The Codex account could not be prepared safely: \(message)"
        case .quitRejected:
            return "Codex did not accept the restart request. Finish any open dialog and try again."
        case .quitTimedOut:
            return "Codex is still closing. Finish any active prompt and try again."
        case .relaunchFailed(let message):
            return "Codex could not be reopened: \(message)"
        case .relaunchTimedOut:
            return "Codex did not reopen in time."
        }
    }
}

@MainActor
final class CodexDesktopController {
    nonisolated static let bundleIdentifier = "com.openai.codex"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var isRunning: Bool {
        !runningApplications.isEmpty
    }

    func restart(
        using profile: AccountProfile,
        previousDesktopProfile: AccountProfile?,
        quitTimeout: TimeInterval = 12,
        launchTimeout: TimeInterval = 15
    ) async throws {
        let appURL = try locateApplication()
        let sharedCodexHomeURL = try resolveSharedCodexHome()
        let targetCredentialURL = try credentialURL(for: profile)
        let targetCredential: Data
        do {
            targetCredential = try Data(contentsOf: targetCredentialURL)
        } catch {
            throw CodexDesktopError.credentialMissing(targetCredentialURL.path)
        }

        let sharedCredentialURL = sharedCodexHomeURL.appendingPathComponent("auth.json")
        let previousSharedCredential = try? Data(contentsOf: sharedCredentialURL)
        let applications = runningApplications

        if !applications.isEmpty {
            guard applications.allSatisfy({ $0.terminate() }) else {
                throw CodexDesktopError.quitRejected
            }

            let quitDeadline = Date().addingTimeInterval(quitTimeout)
            while applications.contains(where: { !$0.isTerminated }) {
                guard Date() < quitDeadline else {
                    throw CodexDesktopError.quitTimedOut
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        do {
            if let previousDesktopProfile,
               previousDesktopProfile.id != profile.id,
               let previousSharedCredential {
                let previousCredentialURL = try credentialURL(for: previousDesktopProfile)
                try writeCredential(previousSharedCredential, to: previousCredentialURL)
            }
            try writeCredential(targetCredential, to: sharedCredentialURL)
        } catch {
            try? restoreCredential(previousSharedCredential, to: sharedCredentialURL)
            try? await launch(
                appURL: appURL,
                codexHomeURL: sharedCodexHomeURL,
                launchTimeout: launchTimeout
            )
            if let error = error as? CodexDesktopError {
                throw error
            }
            throw CodexDesktopError.credentialSwapFailed(error.localizedDescription)
        }

        do {
            try await launch(
                appURL: appURL,
                codexHomeURL: sharedCodexHomeURL,
                launchTimeout: launchTimeout
            )
        } catch {
            try? restoreCredential(previousSharedCredential, to: sharedCredentialURL)
            try? await launch(
                appURL: appURL,
                codexHomeURL: sharedCodexHomeURL,
                launchTimeout: launchTimeout
            )
            throw error
        }

        runningApplications.first?.activate(options: [.activateIgnoringOtherApps])
    }

    nonisolated static func openArguments(
        appURL: URL,
        codexHomeURL: URL
    ) -> [String] {
        [
            "--env",
            "CODEX_HOME=\(codexHomeURL.path)",
            "-a",
            appURL.path
        ]
    }

    private var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
    }

    private func resolveSharedCodexHome() throws -> URL {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodexDesktopError.profileHomeMissing(url.path)
        }
        return url
    }

    private func credentialURL(for profile: AccountProfile) throws -> URL {
        guard let path = profile.codexHomePath else {
            throw CodexDesktopError.profileHomeMissing(profile.displayName)
        }
        let profileHomeURL = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: profileHomeURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodexDesktopError.profileHomeMissing(profileHomeURL.path)
        }
        return profileHomeURL.appendingPathComponent("auth.json")
    }

    private func writeCredential(_ credential: Data, to url: URL) throws {
        do {
            try credential.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw CodexDesktopError.credentialSwapFailed(error.localizedDescription)
        }
    }

    private func restoreCredential(_ credential: Data?, to url: URL) throws {
        if let credential {
            try writeCredential(credential, to: url)
        } else if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw CodexDesktopError.credentialSwapFailed(error.localizedDescription)
            }
        }
    }

    private func launch(
        appURL: URL,
        codexHomeURL: URL,
        launchTimeout: TimeInterval
    ) async throws {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = Self.openArguments(
            appURL: appURL,
            codexHomeURL: codexHomeURL
        )

        do {
            try launcher.run()
            launcher.waitUntilExit()
        } catch {
            throw CodexDesktopError.relaunchFailed(error.localizedDescription)
        }

        guard launcher.terminationStatus == 0 else {
            throw CodexDesktopError.relaunchFailed(
                "the system launcher exited with status \(launcher.terminationStatus)"
            )
        }

        let launchDeadline = Date().addingTimeInterval(launchTimeout)
        while runningApplications.isEmpty {
            guard Date() < launchDeadline else {
                throw CodexDesktopError.relaunchTimedOut
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func locateApplication() throws -> URL {
        if let runningURL = runningApplications.compactMap(\.bundleURL).first {
            return runningURL
        }

        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Codex.app", isDirectory: true)
        ]

        guard let appURL = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw CodexDesktopError.applicationNotFound
        }
        return appURL
    }
}
