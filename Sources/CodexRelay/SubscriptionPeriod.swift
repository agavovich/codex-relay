import Foundation
import SwiftUI

/// Cached authorization metadata, not a live billing or renewal status.
struct SubscriptionPeriod: Equatable {
    let end: Date

    static func read(for profile: AccountProfile) -> Self? {
        let home = profile.codexHomePath
            ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let url = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String else { return nil }
        return decode(token)
    }

    static func decode(_ token: String) -> Self? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let raw = auth["chatgpt_subscription_active_until"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let end = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            return nil
        }
        return Self(end: end)
    }

    func label(now: Date) -> String {
        let date = L10n.date(end)
        guard end > now else { return L10n.tr("Period ended \(date) · refresh needed") }
        let days = Int(ceil(end.timeIntervalSince(now) / 86_400))
        let remaining = end.timeIntervalSince(now) < 86_400 ? L10n.tr("Less than a day left") : L10n.tr("\(L10n.duration(days, unit: .day, full: true)) left")
        return L10n.tr("Paid through \(date) · \(remaining)")
    }
}

struct SubscriptionPeriodLabel: View {
    @Environment(\.locale) private var interfaceLocale
    let period: SubscriptionPeriod
    let now: Date

    var body: some View {
        Text(period.label(now: now))
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .help(L10n.tr("Paid period recorded at sign-in: \(L10n.date(period.end, includeTime: true)). May be outdated after billing changes. Automatic renewal status is unavailable."))
    }
}
