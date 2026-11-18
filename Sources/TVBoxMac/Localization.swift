import Foundation

/// Main-bundle resources are shared by SwiftUI, AppKit panels and system menus.
/// Content supplied by subscriptions is displayed verbatim; callers translate
/// only application-owned labels, keeping persisted identifiers independent.
enum L10n {
    static var isEnglish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true }

    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
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
