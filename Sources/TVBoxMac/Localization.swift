import Foundation

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var localization: String? { self == .system ? nil : rawValue }
    var title: String {
        switch self {
        case .system: return L10n.string("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

enum LanguagePreferences {
    static let key = "interface.language.v1"
    static var store: UserDefaults {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test") else { return .standard }
        let index = arguments.firstIndex(of: "--ui-test-suite")
        let suite = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "local.tvboxmac.ui-test"
        return UserDefaults(suiteName: suite + ".language") ?? .standard
    }
    static func selection(in defaults: UserDefaults = store) -> InterfaceLanguage {
        InterfaceLanguage(rawValue: defaults.string(forKey: key) ?? "") ?? .system
    }
    static func save(_ value: InterfaceLanguage, in defaults: UserDefaults = store) {
        defaults.set(value.rawValue, forKey: key)
    }
    /// Override only this launch's argument domain, above macOS's application
    /// and global preferences. The system's persistent AppleLanguages stays intact.
    static func prepareForLaunch() {
        guard let language = selection().localization else { return }
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain["AppleLanguages"] = [language]
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}

/// Main-bundle resources are shared by SwiftUI, AppKit panels and system menus.
/// Content supplied by subscriptions is displayed verbatim; callers translate
/// only application-owned labels, keeping persisted identifiers independent.
enum L10n {
    // Freeze the active language for the launch. A saved change remains pending
    // until reopening, so menus, system panels and playback UI switch together.
    static let appliedLanguage = LanguagePreferences.selection()
    static var languageCode: String { appliedLanguage.localization ?? Bundle.main.preferredLocalizations.first ?? "en" }
    static var isEnglish: Bool { languageCode.hasPrefix("en") }
    static var locale: Locale { Locale(identifier: languageCode) }

    static func string(_ key: String, bundle: Bundle = .main) -> String {
        let localized: Bundle
        if let language = appliedLanguage.localization, let path = bundle.path(forResource: language, ofType: "lproj"), let selected = Bundle(path: path) { localized = selected }
        else { localized = bundle }
        return localized.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func channelGroup(_ name: String, automatic: Bool) -> String {
        automatic || name == "全部" ? string(name) : name
    }

    static func text(_ message: Message, bundle: Bundle = .main) -> String {
        let format = string(message.key, bundle: bundle)
        guard !message.arguments.isEmpty else { return format.replacingOccurrences(of: "%%", with: "%") }
        return String(format: format, locale: Locale.current, arguments: message.arguments)
    }

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]
        init(stringLiteral value: String) { key = value.replacingOccurrences(of: "%", with: "%%"); arguments = [] }
        init(stringInterpolation value: StringInterpolation) { key = value.key; arguments = value.arguments }
        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
            mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
            mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
        }
    }
}
