import Foundation

// Compile with Models.swift, ConfigurationPayload.swift and Parsers.swift.
// Prints structural counts only; it does not fetch sources, JARs, or channels.
@main struct ConfigCheck {
    static func main() {
        do {
            guard CommandLine.arguments.count > 1 else { throw TVError.message("Usage: check-config FILE [BASE_URL]") }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let base = CommandLine.arguments.count > 2 ? URL(string: CommandLine.arguments[2]) : nil
            let configuration = try Parser.configuration(data, base: base)
            let types = Dictionary(grouping: configuration.sites, by: \.type).mapValues(\.count)
            print("PASS: \(configuration.sites.count) sites; \(configuration.sites.filter(\.supported).count) supported; types \(types); \(configuration.feeds.count) live feeds; \(configuration.channels.count) inline channels; \(configuration.subscriptions.count) subscriptions")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
