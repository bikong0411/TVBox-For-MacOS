import Foundation

// Compile alongside Models.swift and SourceLibrary.swift. Reports metadata only.
@main struct StorageProfile {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let plist = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let root = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
        guard let original = root["sourceLibrary.v1"] as? Data else { return }
        let library = try JSONDecoder().decode(SourceLibrary.self, from: original)
        var compact = library
        let changed = compact.compactPayloads()
        func measure<T: Encodable>(_ value: T) throws -> (Int, Double) {
            let start = CFAbsoluteTimeGetCurrent(); var bytes = 0
            for _ in 0..<5 { bytes = try JSONEncoder().encode(value).count }
            return (bytes, (CFAbsoluteTimeGetCurrent() - start) * 1000 / 5)
        }
        let before = try measure(library), after = try measure(compact), selection = try measure(compact.selection)
        print("Sources: VOD \(library.vodSources.count), live \(library.liveSources.count); compacted: \(changed)")
        print(String(format: "Before: %d bytes, encode mean %.2f ms", before.0, before.1))
        print(String(format: "Compacted: %d bytes, encode mean %.2f ms", after.0, after.1))
        print(String(format: "Selection only: %d bytes, encode mean %.3f ms", selection.0, selection.1))
        print("Source IDs and selection preserved: \(library.vodSources.map(\.id) == compact.vodSources.map(\.id) && library.liveSources.map(\.id) == compact.liveSources.map(\.id) && library.selectedVODID == compact.selectedVODID && library.selectedLiveID == compact.selectedLiveID)")
    }
}
