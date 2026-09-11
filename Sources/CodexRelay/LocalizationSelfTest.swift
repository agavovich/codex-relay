import Foundation

@MainActor
enum LocalizationSelfTest {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append("Localization: " + message) }
        }
        expect(AppLanguage.all.count == 20, "expected 20 languages")
        for (preferences, expected) in [
            (["ru-RU"], "ru"), (["es-MX"], "es"), (["pt-PT"], "pt-BR"),
            (["zh-TW"], "zh-Hant"), (["zh-HK"], "zh-Hant"),
            (["zh-Hans-HK"], "zh-Hans"), (["zh-CN"], "zh-Hans"),
            (["sv-SE", "uk-UA", "en-US"], "uk"), (["sv-SE"], "en"),
            ([String](), "en")
        ] {
            expect(AppLanguage.resolve("system", preferred: preferences) == expected, "preference matching \(preferences)")
        }
        expect(AppLanguage.resolve("ja", preferred: ["ru-RU"]) == "ja", "manual override must win")
        expect(AppLanguage.resolve("invalid", preferred: ["de-DE"]) == "de", "invalid saved choice fallback")
        let keys = Set(L10n.catalog["en"]?.keys.map { $0 } ?? [])
        expect(keys.count >= 160, "resource catalog missing or incomplete")
        let regex = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ string: String) -> [String] {
            regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
                .map { String(string[Range($0.range, in: string)!]) }.sorted()
        }
        for language in AppLanguage.all {
            let entries = L10n.catalog[language.id] ?? [:]
            expect(Set(entries.keys) == keys, "missing keys for \(language.id)")
            for (key, value) in entries {
                expect(!value.isEmpty && placeholders(key) == placeholders(value), "invalid placeholders: \(language.id) / \(key)")
            }
        }
        expect(L10n.render(key: "Paid through {0} · {1}", arguments: ["{1}", "test"], language: "en") == "Paid through {1} · test", "interpolation must not reinterpret user data")
        expect(L10n.render(key: "Unknown key", language: "ru") == "Unknown key", "missing-key fallback")
        let suite = "CodexRelay.LocalizationTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); L10n.configure("en") }
        let settings = AppSettings(defaults: defaults)
        expect(settings.language == "system", "first launch must follow system")
        settings.language = "ru"
        expect(AppSettings(defaults: defaults).language == "ru", "manual selection must persist")
        expect(L10n.tr("Settings") == "Настройки", "live language change")
        for days in [1, 2, 5, 21, 24] {
            let text = L10n.duration(days, unit: .day, full: true)
            expect(text.contains("д"), "Russian duration must be localized: \(text)")
        }
        settings.language = "ar"
        expect(L10n.direction == .rightToLeft, "Arabic direction")
        settings.language = "system"
        expect(AppSettings(defaults: defaults).language == "system", "system mode must persist")
        return failures
    }
}
