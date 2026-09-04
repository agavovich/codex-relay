import AppKit
import Foundation

struct UpdateRelease: Equatable {
    let version: String
    let name: String
    let notes: String?
    let pageURL: URL
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(latestVersion: String)
    case updateAvailable(UpdateRelease)
    case failed(String)
}

enum ReleaseVersion {
    static func normalized(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = components(candidate)
        let currentParts = components(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }

        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private static func components(_ rawValue: String) -> [Int] {
        normalized(rawValue)
            .split(separator: ".")
            .compactMap { component in
                let digits = component.prefix(while: \.isNumber)
                return digits.isEmpty ? nil : Int(digits)
            }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case invalidReleaseURL
        case requestFailed(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "GitHub returned an invalid release response."
            case .invalidReleaseURL:
                return "GitHub returned an invalid release link."
            case .requestFailed(let statusCode):
                return "GitHub returned HTTP \(statusCode). Please try again later."
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    func check(interactive: Bool = true) {
        guard state != .checking else { return }
        state = .checking

        Task {
            do {
                let release = try await fetchLatestRelease()
                if ReleaseVersion.isNewer(release.version, than: currentVersion) {
                    state = .updateAvailable(release)
                } else {
                    state = .upToDate(latestVersion: release.version)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }

            if interactive {
                presentCurrentResult()
            }
        }
    }

    func openAvailableRelease() {
        guard case .updateAvailable(let release) = state else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    private func fetchLatestRelease() async throws -> UpdateRelease {
        guard let url = URL(
            string: "https://api.github.com/repos/agavovich/codex-relay/releases/latest"
        ) else {
            throw UpdateError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Codex-Relay/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw UpdateError.requestFailed(httpResponse.statusCode)
        }

        let responseBody = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard responseBody.htmlURL.scheme == "https",
              responseBody.htmlURL.host == "github.com",
              responseBody.htmlURL.path.hasPrefix("/agavovich/codex-relay/") else {
            throw UpdateError.invalidReleaseURL
        }

        let version = ReleaseVersion.normalized(responseBody.tagName)
        guard !version.isEmpty else { throw UpdateError.invalidResponse }
        return UpdateRelease(
            version: version,
            name: responseBody.name ?? "Codex Relay \(version)",
            notes: responseBody.body,
            pageURL: responseBody.htmlURL
        )
    }

    private func presentCurrentResult() {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch state {
        case .idle, .checking:
            return

        case .upToDate(let latestVersion):
            alert.messageText = "Codex Relay is up to date"
            alert.informativeText = currentVersion == latestVersion
                ? "You’re running the latest version, \(currentVersion)."
                : "Installed: \(currentVersion). Latest public release: \(latestVersion)."
            alert.addButton(withTitle: "OK")

        case .updateAvailable(let release):
            alert.messageText = "Codex Relay \(release.version) is available"
            let notes = release.notes?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(600)
            alert.informativeText = notes.map(String.init)
                ?? "You’re currently running version \(currentVersion)."
            alert.addButton(withTitle: "Open Release")
            alert.addButton(withTitle: "Later")

        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           case .updateAvailable = state {
            openAvailableRelease()
        }
    }
}

enum UpdateCheckerSelfTest {
    static func run() -> [String] {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        expect(
            ReleaseVersion.normalized("v0.6.4") == "0.6.4",
            "release version normalization failed"
        )
        expect(
            ReleaseVersion.isNewer("v0.6.4", than: "0.6.3"),
            "new patch release was not detected"
        )
        expect(
            !ReleaseVersion.isNewer("0.6.3", than: "0.6.3"),
            "identical version was marked as newer"
        )
        expect(
            !ReleaseVersion.isNewer("0.5.2", than: "0.6.3"),
            "older release was marked as newer"
        )
        expect(
            ReleaseVersion.isNewer("1.0", than: "0.9.9"),
            "major release comparison failed"
        )
        return failures
    }
}
