import Foundation

enum CodexPlan {
    static func displayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        switch normalized {
        case "pro", "prolite": return "PRO"
        case "plus": return "PLUS"
        case "free": return "FREE"
        case "team": return "TEAM"
        case "business": return "BUSINESS"
        case "enterprise": return "ENTERPRISE"
        default: return rawValue.uppercased()
        }
    }
}

struct RateLimitWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: TimeInterval?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    var displayTitle: String {
        RateLimitWindowTitle.title(forMinutes: windowDurationMins)
    }

    var isExhausted: Bool {
        remainingPercent < 0.5
    }

    func resetDate(after now: Date) -> Date? {
        guard let resetsAt else { return nil }
        return max(Date(timeIntervalSince1970: resetsAt), now)
    }
}

enum RateLimitCountdown {
    static func text(until timestamp: TimeInterval?, now: Date) -> String {
        guard let timestamp else { return "—" }
        return text(until: Date(timeIntervalSince1970: timestamp), now: now)
    }

    static func text(until date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        if seconds < 60 { return "<1m" }

        let totalMinutes = Int(ceil(seconds / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

enum RateLimitWindowTitle {
    static func title(forMinutes minutes: Int) -> String {
        let safeMinutes = max(0, minutes)

        if safeMinutes == 10_080 {
            return "WEEK"
        }

        if safeMinutes > 0, safeMinutes.isMultiple(of: 10_080) {
            let weeks = safeMinutes / 10_080
            return "\(weeks) \(unit(weeks, singular: "week", plural: "weeks"))"
                .uppercased()
        }

        if safeMinutes > 0, safeMinutes.isMultiple(of: 1_440) {
            let days = safeMinutes / 1_440
            return "\(days) \(unit(days, singular: "day", plural: "days"))"
                .uppercased()
        }

        if safeMinutes > 0, safeMinutes.isMultiple(of: 60) {
            let hours = safeMinutes / 60
            return "\(hours) \(unit(hours, singular: "hour", plural: "hours"))"
                .uppercased()
        }

        return "\(safeMinutes) \(unit(safeMinutes, singular: "minute", plural: "minutes"))"
            .uppercased()
    }

    private static func unit(
        _ value: Int,
        singular: String,
        plural: String
    ) -> String {
        abs(value) == 1 ? singular : plural
    }
}

struct CreditBalance: Codable, Equatable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct RateLimitSnapshot: Codable, Equatable {
    let limitId: String
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditBalance?
    let spendControlReached: Bool?
    let planType: String?
    let rateLimitReachedType: String?

    var displayWindows: [RateLimitWindow] {
        [primary, secondary]
            .compactMap { $0 }
            .sorted {
                if $0.windowDurationMins != $1.windowDurationMins {
                    return $0.windowDurationMins < $1.windowDurationMins
                }
                return ($0.resetsAt ?? .greatestFiniteMagnitude)
                    < ($1.resetsAt ?? .greatestFiniteMagnitude)
            }
    }

    var preferredHUDWindow: RateLimitWindow? {
        let windows = displayWindows
        return windows.first(where: { $0.windowDurationMins == 300 })
            ?? windows.first(where: { $0.windowDurationMins == 10_080 })
            ?? windows.first
    }

    var isExhausted: Bool {
        rateLimitReachedType != nil || displayWindows.contains(where: \.isExhausted)
    }

    var usableHeadroom: Double {
        displayWindows.map(\.remainingPercent).min() ?? 0
    }

    func nextAvailableDate(now: Date) -> Date? {
        guard isExhausted else { return now }

        let reachedType = rateLimitReachedType?.lowercased()
        if let reachedType {
            if reachedType.contains("primary"), let primary {
                return primary.resetDate(after: now)
            }
            if reachedType.contains("secondary"), let secondary {
                return secondary.resetDate(after: now)
            }
        }

        let exhaustedWindows = displayWindows.filter(\.isExhausted)
        let resetDates = exhaustedWindows.compactMap { $0.resetDate(after: now) }
        if !resetDates.isEmpty {
            // Every exhausted window must reset before the account is usable.
            return resetDates.max()
        }

        // The server reported a reached limit without identifying its window.
        return displayWindows.compactMap { $0.resetDate(after: now) }.min()
    }
}

struct RateLimitResetCredits: Codable, Equatable {
    let availableCount: Int
}

struct RateLimitsResult: Codable, Equatable {
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCredits?

    var codexLimit: RateLimitSnapshot? {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

struct CodexAccountInfo: Codable, Equatable {
    let type: String
    let email: String?
    let planType: String?
}

struct AccountReadResult: Codable, Equatable {
    let account: CodexAccountInfo?
    let requiresOpenaiAuth: Bool
}

struct AccountUsageResult: Equatable {
    let account: CodexAccountInfo?
    let requiresOpenaiAuth: Bool
    let rateLimits: RateLimitsResult
}

struct RPCErrorPayload: Codable, Equatable {
    let code: Int
    let message: String
}

struct RPCResponse<Result: Decodable>: Decodable {
    let id: Int
    let result: Result?
    let error: RPCErrorPayload?
}
