import Foundation
import Testing
@testable import TVBoxCore

@Suite struct ApplicationUpdateTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    @Test func releaseFeedsMatchTheActualExecutableArchitecture() throws {
        let config = try ApplicationUpdateConfiguration(repository: "https://github.com/example/TVBox.git/", publicKey: key)
        #expect(config.repository == "example/TVBox")
        #expect(config.feedURL(for: .intel).absoluteString == "https://github.com/example/TVBox/releases/latest/download/appcast-Intel.xml")
        #expect(config.feedURL(for: .appleSilicon).lastPathComponent == "appcast-AppleSilicon.xml")
        #expect(config.releasesURL.absoluteString == "https://github.com/example/TVBox/releases")
    }
    @Test func invalidRepositoriesAndSigningKeysAreRejected() {
        for repository in ["http://github.com/owner/repo", "https://user@github.com/owner/repo", "https://github.com.evil.invalid/owner/repo", "https://github.com/owner/repo?key=x", "https://github.com:443/owner/repo", "owner/repo/extra", "owner/..", "owner/repo#fragment", "../repo"] {
            #expect(throws: (any Error).self) { try ApplicationUpdateConfiguration(repository: repository, publicKey: key) }
        }
        for key in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            #expect(throws: (any Error).self) { try ApplicationUpdateConfiguration(repository: "owner/repo", publicKey: key) }
        }
    }
}
