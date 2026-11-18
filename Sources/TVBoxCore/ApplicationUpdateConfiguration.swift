import Foundation

public enum UpdateArchitecture: String, Sendable, CaseIterable {
    case intel = "Intel"
    case appleSilicon = "AppleSilicon"
    public static var current: UpdateArchitecture {
        #if arch(x86_64)
        return .intel
        #else
        return .appleSilicon
        #endif
    }
}

/// Release feeds are tied to one repository and one archive architecture.
public struct ApplicationUpdateConfiguration: Equatable, Sendable {
    public let repository: String
    public let publicKey: String
    public init(repository raw: String, publicKey: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository: String
        if value.hasPrefix("https://") {
            guard let url = URLComponents(string: value), url.host?.lowercased() == "github.com",
                  url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw TVError.message("更新仓库必须是完整的 GitHub 仓库地址。")
            }
            repository = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { repository = value }
        let normalized = repository.hasSuffix(".git") ? String(repository.dropLast(4)) : repository
        guard normalized.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil,
              ![".", ".."].contains(String(normalized.split(separator: "/").last ?? "")),
              let bytes = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 32 else {
            throw TVError.message("更新仓库或更新签名公钥尚未正确配置。")
        }
        self.repository = normalized
        self.publicKey = bytes.base64EncodedString()
    }
    public func feedURL(for architecture: UpdateArchitecture = .current) -> URL {
        URL(string: "https://github.com/\(repository)/releases/latest/download/appcast-\(architecture.rawValue).xml")!
    }
    public var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }
}
