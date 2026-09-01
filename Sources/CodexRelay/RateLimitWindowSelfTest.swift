import Foundation

enum RateLimitWindowSelfTest {
    static func run() -> [String] {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let weeklyOnly = makeSnapshot(
            primary: makeWindow(minutes: 10_080, usedPercent: 1),
            secondary: nil
        )
        let summaryNow = Date(timeIntervalSince1970: 1_799_996_400)
        expect(
            weeklyOnly.displayWindows.map(\.windowDurationMins) == [10_080],
            "weekly-only window was not preserved"
        )
        expect(
            weeklyOnly.displayWindows.first?.displayTitle == "WEEK",
            "weekly-only window received the wrong title"
        )
        expect(
            weeklyOnly.displayWindows.first?.remainingPercent == 99,
            "weekly-only remaining percentage is wrong"
        )
        expect(
            ProfileLimitState(snapshot: weeklyOnly).compactSummary(now: summaryNow)
                == "WEEK 99% · ↻ 1h 0m",
            "weekly-only account summary is wrong"
        )

        let reversed = makeSnapshot(
            primary: makeWindow(minutes: 10_080),
            secondary: makeWindow(minutes: 300)
        )
        expect(
            reversed.displayWindows.map(\.windowDurationMins) == [300, 10_080],
            "reversed windows were not sorted by duration"
        )
        expect(
            reversed.displayWindows.map(\.displayTitle) == ["5 HOURS", "WEEK"],
            "sorted windows received the wrong titles"
        )
        expect(
            reversed.preferredHUDWindow?.windowDurationMins == 300,
            "five-hour window was not preferred in the collapsed HUD"
        )
        expect(
            weeklyOnly.preferredHUDWindow?.windowDurationMins == 10_080,
            "weekly window was not used as the collapsed HUD fallback"
        )

        let unknownOnly = makeSnapshot(
            primary: makeWindow(minutes: 1_440),
            secondary: nil
        )
        expect(
            unknownOnly.preferredHUDWindow?.windowDurationMins == 1_440,
            "unknown server window was not preserved as the final HUD fallback"
        )

        let commonOrder = makeSnapshot(
            primary: makeWindow(minutes: 300),
            secondary: makeWindow(minutes: 10_080)
        )
        expect(
            commonOrder.displayWindows.map(\.displayTitle) == ["5 HOURS", "WEEK"],
            "common primary-secondary order changed"
        )
        expect(
            ProfileLimitState(snapshot: commonOrder).compactSummary(now: summaryNow)
                == "5 HOURS 75% · ↻ 1h 0m\nWEEK 75% · ↻ 1h 0m",
            "two-window account summary is wrong"
        )

        expect(
            RateLimitCountdown.text(
                until: summaryNow.addingTimeInterval(2 * 86_400 + 3 * 3_600).timeIntervalSince1970,
                now: summaryNow
            ) == "2d 3h",
            "multi-day reset countdown is wrong"
        )
        expect(
            RateLimitCountdown.text(
                until: summaryNow.addingTimeInterval(30).timeIntervalSince1970,
                now: summaryNow
            ) == "<1m",
            "sub-minute reset countdown is wrong"
        )
        expect(
            RateLimitCountdown.text(until: summaryNow, now: summaryNow) == "now",
            "completed reset countdown is wrong"
        )

        let exhaustedShortWindow = makeSnapshot(
            primary: makeWindow(
                minutes: 300,
                usedPercent: 100,
                resetsAt: summaryNow.addingTimeInterval(3_600).timeIntervalSince1970
            ),
            secondary: makeWindow(
                minutes: 10_080,
                resetsAt: summaryNow.addingTimeInterval(86_400).timeIntervalSince1970
            )
        )
        expect(exhaustedShortWindow.isExhausted, "exhausted window was not detected")
        expect(
            exhaustedShortWindow.nextAvailableDate(now: summaryNow)
                == summaryNow.addingTimeInterval(3_600),
            "single blocking-window reset was not selected"
        )

        let twoBlockingWindows = makeSnapshot(
            primary: makeWindow(
                minutes: 300,
                usedPercent: 100,
                resetsAt: summaryNow.addingTimeInterval(3_600).timeIntervalSince1970
            ),
            secondary: makeWindow(
                minutes: 10_080,
                usedPercent: 100,
                resetsAt: summaryNow.addingTimeInterval(7_200).timeIntervalSince1970
            )
        )
        expect(
            twoBlockingWindows.nextAvailableDate(now: summaryNow)
                == summaryNow.addingTimeInterval(7_200),
            "account was marked available before all blocking windows reset"
        )

        let serverIdentifiedWindow = makeSnapshot(
            primary: makeWindow(
                minutes: 300,
                resetsAt: summaryNow.addingTimeInterval(3_600).timeIntervalSince1970
            ),
            secondary: makeWindow(
                minutes: 10_080,
                resetsAt: summaryNow.addingTimeInterval(7_200).timeIntervalSince1970
            ),
            rateLimitReachedType: "secondary"
        )
        expect(
            serverIdentifiedWindow.nextAvailableDate(now: summaryNow)
                == summaryNow.addingTimeInterval(7_200),
            "server-identified blocking window was ignored"
        )

        let readyLow = AccountSwitchRecommendation(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            availableAt: .distantPast,
            usableHeadroom: 20
        )
        let readyHigh = AccountSwitchRecommendation(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            availableAt: .distantPast,
            usableHeadroom: 80
        )
        let waitingSoon = AccountSwitchRecommendation(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            availableAt: summaryNow.addingTimeInterval(600),
            usableHeadroom: 0
        )
        let waitingLater = AccountSwitchRecommendation(
            profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!,
            availableAt: summaryNow.addingTimeInterval(1_200),
            usableHeadroom: 0
        )
        expect(
            AccountSwitchAdvisor.best(
                from: [waitingSoon, readyLow, readyHigh],
                now: summaryNow
            ) == readyHigh,
            "best currently available account was not recommended"
        )
        expect(
            AccountSwitchAdvisor.best(
                from: [waitingLater, waitingSoon],
                now: summaryNow
            ) == waitingSoon,
            "earliest future reset was not recommended"
        )

        expect(makeWindow(minutes: 1_440).displayTitle == "1 DAY", "one-day title is wrong")
        expect(makeWindow(minutes: 2_880).displayTitle == "2 DAYS", "two-day title is wrong")
        expect(makeWindow(minutes: 90).displayTitle == "90 MINUTES", "minute title is wrong")

        let launchArguments = CodexDesktopController.openArguments(
            appURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            codexHomeURL: URL(fileURLWithPath: "/tmp/codex profile")
        )
        expect(
            launchArguments == [
                "--env",
                "CODEX_HOME=/tmp/codex profile",
                "-a",
                "/Applications/ChatGPT.app"
            ],
            "Codex desktop launch arguments are wrong"
        )

        return failures
    }

    private static func makeWindow(
        minutes: Int,
        usedPercent: Double = 25,
        resetsAt: TimeInterval = 1_800_000_000
    ) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: minutes,
            resetsAt: resetsAt
        )
    }

    private static func makeSnapshot(
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        rateLimitReachedType: String? = nil
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: primary,
            secondary: secondary,
            credits: nil,
            spendControlReached: nil,
            planType: "plus",
            rateLimitReachedType: rateLimitReachedType
        )
    }
}
