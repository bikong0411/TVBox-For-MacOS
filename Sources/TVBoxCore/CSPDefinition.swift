import Foundation

/// Original TVBox spider metadata. Kept with the site so history and separate
/// subscriptions cannot accidentally execute a different configuration's JAR.
public struct CSPDefinition: Codable, Hashable, Sendable {
    public let component: CSPComponent
    public let className: String
    public let extend: String
    public let configurationURL: URL?
    public init(component: CSPComponent, api: String, extend: String = "", configurationURL: URL? = nil) throws {
        guard api.hasPrefix("csp_") else { throw TVError.message("CSP 接口类名无效。") }
        let name = String(api.dropFirst(4))
        guard name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil,
              name.count <= 160 else { throw TVError.message("CSP 接口类名无效。") }
        self.component = component; className = "com.github.catvod.spider." + name; self.extend = extend; self.configurationURL = configurationURL
    }
}

public struct CSPComponent: Codable, Hashable, Sendable {
    public enum Algorithm: String, Codable, Sendable { case md5, sha256 }
    public let url: URL
    public let algorithm: Algorithm?
    public let digest: String?
    public init(_ raw: String, base: URL? = nil) throws {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ";")
        guard parts.count == 1 || parts.count == 3,
              let first = parts.first, !first.isEmpty,
              let url = URL(string: first, relativeTo: base)?.absoluteURL,
              ["https", "http", "file"].contains(url.scheme?.lowercased() ?? ""),
              url.isFileURL || url.host != nil else { throw TVError.message("爬虫组件地址无效。") }
        self.url = url
        if parts.count == 3 {
            guard let algorithm = Algorithm(rawValue: parts[1].lowercased()),
                  parts[2].count == (algorithm == .md5 ? 32 : 64),
                  parts[2].range(of: "^[a-fA-F0-9]+$", options: .regularExpression) != nil else {
                throw TVError.message("爬虫组件校验值无效。")
            }
            self.algorithm = algorithm; digest = parts[2].lowercased()
        } else { algorithm = nil; digest = nil }
    }
}
