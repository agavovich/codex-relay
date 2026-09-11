import Foundation
import SwiftUI

struct AppLanguage: Identifiable {
    let id: String
    let name: String
    static let all: [Self] = [
        .init(id: "en", name: "English"), .init(id: "ru", name: "Русский"),
        .init(id: "es", name: "Español"), .init(id: "fr", name: "Français"),
        .init(id: "de", name: "Deutsch"), .init(id: "pt-BR", name: "Português (Brasil)"),
        .init(id: "zh-Hans", name: "简体中文"), .init(id: "zh-Hant", name: "繁體中文"),
        .init(id: "ja", name: "日本語"), .init(id: "ko", name: "한국어"),
        .init(id: "it", name: "Italiano"), .init(id: "tr", name: "Türkçe"),
        .init(id: "ar", name: "العربية"), .init(id: "hi", name: "हिन्दी"),
        .init(id: "id", name: "Bahasa Indonesia"), .init(id: "vi", name: "Tiếng Việt"),
        .init(id: "th", name: "ไทย"), .init(id: "pl", name: "Polski"),
        .init(id: "uk", name: "Українська"), .init(id: "nl", name: "Nederlands")
    ]

    static func resolve(_ choice: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if all.contains(where: { $0.id == choice }) { return choice }
        for raw in preferred {
            let tag = raw.replacingOccurrences(of: "_", with: "-").lowercased()
            let base = tag.split(separator: "-").first.map(String.init) ?? ""
            if base == "zh" {
                if tag.contains("hans") { return "zh-Hans" }
                return tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo")
                    ? "zh-Hant" : "zh-Hans"
            }
            if base == "pt" { return "pt-BR" }
            if base == "in" { return "id" }
            if all.contains(where: { $0.id == base }) { return base }
        }
        return "en"
    }
}

/// Interpolation values are kept separate, so translators may safely reorder them.
struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation value: StringInterpolation) {
        key = value.key; arguments = value.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

enum L10n {
    static let changed = Notification.Name("CodexRelayLanguageChanged")
    private static let lock = NSLock()
    private static var selected = "system"
    static let catalog: [String: [String: String]] = {
        let packaged = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("CodexRelay_CodexRelay.bundle")) }
        let resources = packaged ?? Bundle.module
        guard let url = resources.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return result
    }()
    static var language: String {
        lock.lock(); let choice = selected; lock.unlock()
        return AppLanguage.resolve(choice)
    }
    static var locale: Locale { Locale(identifier: language) }
    static var direction: LayoutDirection { language == "ar" ? .rightToLeft : .leftToRight }
    static func configure(_ choice: String) {
        lock.lock(); selected = choice; lock.unlock()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func tr(_ message: LocalizedMessage) -> String {
        render(key: message.key, arguments: message.arguments, language: language)
    }
    static func render(key: String, arguments: [String] = [], language: String) -> String {
        let template = catalog[language]?[key] ?? catalog["en"]?[key] ?? key
        // One pass: an account name containing {1} must never become a placeholder.
        let regex = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var output = template
        for match in matches.reversed() {
            guard let indexRange = Range(match.range(at: 1), in: template),
                  let index = Int(template[indexRange]), arguments.indices.contains(index),
                  let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: arguments[index])
        }
        return output
    }
    static func duration(_ value: Int, unit: NSCalendar.Unit, full: Bool = false) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = unit
        formatter.unitsStyle = full ? .full : .abbreviated
        var components = DateComponents()
        switch unit {
        case .weekOfMonth: components.weekOfMonth = value
        case .day: components.day = value
        case .hour: components.hour = value
        case .minute: components.minute = value
        default: components.second = value
        }
        return formatter.string(from: components) ?? String(value)
    }
    static func list(_ values: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }
    static func date(_ date: Date, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(includeTime ? "MMMdjm" : "MMMd")
        return formatter.string(from: date)
    }
}
