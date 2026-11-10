import Foundation

/// Immutable, precomputed catalogue for scrolling and searching.
public struct ChannelIndex: Sendable {
    public let channels: [Channel]
    public let groups: [String]
    public let automaticGroups: [String]
    public let routeCount: Int
    private let groupedPositions: [String: [Int]]
    private let classifiedPositions: [String: [Int]]
    private let classifiedOrder: [Int]
    private let searchNames: [String]
    public init(channels input: [Channel]) {
        struct MergeKey: Hashable { var name: String; var group: String; var headers: [String: String] }
        var merged: [Channel] = [], positions: [MergeKey: Int] = [:], seenURLs: [Set<String>] = []
        for var channel in input {
            channel.name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            channel.group = channel.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if channel.group.isEmpty { channel.group = "未分组" }
            let key = MergeKey(name: channel.name, group: channel.group, headers: channel.headers)
            let position: Int
            if let existing = positions[key] { position = existing }
            else {
                position = merged.count; positions[key] = position
                var item = channel; item.urls = []; merged.append(item); seenURLs.append([])
            }
            for rawURL in channel.urls {
                let url = Parser.liveAddress(rawURL)
                if !url.isEmpty && seenURLs[position].insert(url).inserted { merged[position].urls.append(url) }
            }
            if merged[position].logo.isEmpty && !channel.logo.isEmpty { merged[position].logo = channel.logo }
            // Keep metadata paired with its first playback route. Never borrow an
            // archive template from a different provider's alternate route.
            if merged[position].guide == nil && channel.urls.first == merged[position].urls.first { merged[position].guide = channel.guide }
        }
        self.channels = merged.filter { !$0.urls.isEmpty }
        self.routeCount = self.channels.reduce(0) { $0 + $1.urls.count }
        var grouped: [String: [Int]] = [:]
        for (position, channel) in self.channels.enumerated() { grouped[channel.group, default: []].append(position) }
        self.groupedPositions = grouped
        self.groups = ["全部"] + grouped.keys.filter { $0 != "全部" }.sorted()
        var classified: [String: [Int]] = [:]
        for (position, channel) in self.channels.enumerated() { classified[ChannelClassifier.category(for: channel), default: []].append(position) }
        let sortKeys = self.channels.map { ChannelClassifier.sortKey($0.name) }, locale = Locale(identifier: "zh_CN")
        for name in Array(classified.keys) {
            classified[name]?.sort { lhs, rhs in
                let order = sortKeys[lhs].compare(sortKeys[rhs], options: [.numeric], locale: locale)
                return order == .orderedSame ? lhs < rhs : order == .orderedAscending
            }
        }
        self.classifiedPositions = classified
        let categories = ChannelClassifier.order.filter { classified[$0] != nil }
        self.automaticGroups = ["全部"] + categories
        self.classifiedOrder = categories.flatMap { classified[$0] ?? [] }
        self.searchNames = self.channels.map { Self.normalized($0.name) }
    }
    public func groups(for grouping: ChannelGrouping) -> [String] { grouping == .automatic ? automaticGroups : groups }
    public func count(group: String, grouping: ChannelGrouping) -> Int {
        if group == "全部" { return channels.count }
        return (grouping == .automatic ? classifiedPositions[group] : groupedPositions[group])?.count ?? 0
    }
    public func matching(group: String = "全部", query: String = "", grouping: ChannelGrouping = .original) -> [Channel] {
        let needle = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let positions = group == "全部" ? (grouping == .automatic ? classifiedOrder : Array(channels.indices)) : ((grouping == .automatic ? classifiedPositions[group] : groupedPositions[group]) ?? [])
        if needle.isEmpty { return positions.map { channels[$0] } }
        return positions.compactMap { searchNames[$0].contains(needle) ? channels[$0] : nil }
    }
    public func sections(group: String = "全部", query: String = "", grouping: ChannelGrouping = .automatic) -> [ChannelSection] {
        let positions = grouping == .automatic ? classifiedPositions : groupedPositions
        let names = group == "全部" ? (grouping == .automatic ? automaticGroups.filter { $0 != "全部" } : positions.keys.sorted()) : [group]
        let needle = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return names.compactMap { name in
            let items = (positions[name] ?? []).compactMap { needle.isEmpty || searchNames[$0].contains(needle) ? channels[$0] : nil }
            return items.isEmpty ? nil : ChannelSection(name: name, channels: items)
        }
    }
    private static func normalized(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
