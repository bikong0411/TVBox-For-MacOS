import Foundation
import Testing
@testable import TVBoxCore

@Suite struct CSPComponentOverrideTests {
    private func configuration(_ location: String = "https://fixture.invalid/config.json", api: String = "csp_Fixture") throws -> Configuration {
        let definition = try CSPDefinition(component: CSPComponent("https://fixture.invalid/wrong.jar"), api: api, extend: "{\"keep\":true}", configurationURL: URL(string: location))
        return Configuration(name: "Fixture", location: location, sites: [Site(key: "same", name: "CSP", type: 3, api: api, csp: definition)])
    }
    @Test func correctionIsScopedAndSurvivesRefreshAndPersistence() throws {
        var library = SourceLibrary()
        let original = try configuration()
        _ = try library.add(original)
        let first = try #require(library.activeVOD?.id)
        _ = try library.add(configuration("https://other.invalid/config.json"))
        let second = try #require(library.activeVOD?.id)
        let selection = library.selection
        let corrected = try CSPComponent("https://fixture.invalid/correct.jar;sha256;" + String(repeating: "a", count: 64))
        try library.setCSPComponent(corrected, sourceID: first, siteID: "same")
        let source = try #require(library.vodSources.first { $0.id == first })
        #expect(source.runtimeSite("same")?.csp?.component == corrected)
        #expect(source.runtimeSite("same")?.csp?.extend == "{\"keep\":true}")
        #expect(source.runtimeSite("same")?.key == first + "::same")
        #expect(library.activeVOD?.id == second && library.activeVOD?.runtimeSite("same")?.csp?.component != corrected)
        _ = try library.add(original, activate: false)
        library = try JSONDecoder().decode(SourceLibrary.self, from: JSONEncoder().encode(library))
        library.restoreSelection(selection)
        #expect(library.vodSources.first { $0.id == first }?.runtimeSite("same")?.csp?.component == corrected)
        #expect(library.activeVOD?.id == second)
        try library.setCSPComponent(nil, sourceID: first, siteID: "same")
        #expect(library.vodSources.first { $0.id == first }?.runtimeSite("same")?.csp?.component == original.sites[0].csp?.component)
    }
    @Test func aDifferentAPIDoesNotReuseCorrectionAndChangingSourceURLClearsIt() throws {
        var library = SourceLibrary();_ = try library.add(configuration())
        let id = try #require(library.activeVOD?.id), corrected = try CSPComponent("https://fixture.invalid/correct.jar")
        try library.setCSPComponent(corrected, sourceID: id, siteID: "same")
        _ = try library.add(configuration(api: "csp_Different"))
        #expect(library.activeVOD?.runtimeSite("same")?.csp?.component != corrected)
        try library.replaceVOD(id, configuration: configuration("https://new.invalid/config.json"), name: "Replacement")
        #expect(library.activeVOD?.componentOverrides == nil && library.activeVOD?.id == id)
        #expect(throws: (any Error).self) { try library.setCSPComponent(corrected, sourceID: id, siteID: "missing") }
    }
}
