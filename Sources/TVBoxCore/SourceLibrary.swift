import Foundation

public enum SourceImportTarget: String, Codable, CaseIterable, Identifiable {
    case automatic = "自动识别"
    case vod = "仅点播源"
    case live = "仅直播源"
    public var id: String { rawValue }
}

public struct CSPComponentOverride: Codable, Equatable, Sendable {
    public let api: String
    public let component: CSPComponent
    public init(api: String, component: CSPComponent) { self.api = api; self.component = component }
}

public struct SavedVODSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var origin: String
    public var configuration: Configuration
    public var selectedSiteID: String
    public var componentOverrides: [String: CSPComponentOverride]? = nil
    /// Stage a refresh from this subscription, without changing saved state.
    /// The caller commits only after the new, verified component works.
    public func refreshingCSP(_ configuration: Configuration, siteID: String) throws -> SavedVODSource {
        guard let previous = self.configuration.sites.first(where: { $0.key == siteID }), previous.requiresCSP,
              configuration.location == origin,
              let current = configuration.sites.first(where: { $0.key == siteID }),
              current.api == previous.api, current.requiresCSP,
              let component = current.csp?.component,
              component.algorithm != nil, component.digest != nil,
              previous.csp?.component.algorithm != .sha256 || component.algorithm == .sha256 else {
            throw CSPFailure.interfaceChanged
        }
        if componentOverrides?[siteID]?.api == previous.api { throw CSPFailure.localComponentMismatch }
        var result = self
        result.configuration = Configuration(name: configuration.name, location: configuration.location, sites: configuration.sites, subscriptions: configuration.subscriptions)
        return result
    }
    public func runtimeSite(_ key: String) -> Site? {
        guard var site = configuration.sites.first(where: { $0.key == key }) else { return nil }
        if let override = componentOverrides?[key], override.api == site.api, let original = site.csp {
            site.csp = try? CSPDefinition(component: override.component, api: site.api, extend: original.extend, configurationURL: original.configurationURL)
        }
        // Identical CMS keys and video IDs in separate configurations must not
        // collide in favorites or playback history.
        site.key = id + "::" + site.key
        return site
    }
}

public struct SavedLiveSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var origin: String
    public var configuration: Configuration
    public var feedURL: String?
    public var feeds: [LiveFeed] { configuration.feeds.filter { $0.url == feedURL } }
    public var channels: [Channel] { feedURL == nil ? configuration.channels : [] }
    public var subscriptions: [Subscription] { feedURL == nil ? configuration.subscriptions : [] }
}

public struct SourceImportResult {
    public var updatedVOD: Bool
    public var updatedLive: Bool
}

/// The two selections are independent. Import validation happens before mutation.
public struct SourceLibrary: Codable, Sendable {
    public private(set) var vodSources: [SavedVODSource] = []
    public private(set) var liveSources: [SavedLiveSource] = []
    public private(set) var selectedVODID: String?
    public private(set) var selectedLiveID: String?
    public var activeVOD: SavedVODSource? { vodSources.first { $0.id == selectedVODID } }
    public var activeLive: SavedLiveSource? { liveSources.first { $0.id == selectedLiveID } }
    public init() {}

    public static func migrating(_ legacy: Configuration?, siteID: String = "") -> SourceLibrary {
        var library = SourceLibrary()
        if let legacy {
            _ = try? library.add(legacy)
            library.selectSite(siteID)
        }
        return library
    }

    public func scopeLegacyEntries(_ entries: [LibraryEntry], legacyLocation: String) -> [LibraryEntry] {
        guard let source = vodSources.first(where: { $0.configuration.location == legacyLocation }) else { return entries }
        return entries.map { entry in
            guard let site = entry.site,
                  source.configuration.sites.contains(where: { $0.key == site.key && $0.api == site.api }),
                  let scoped = source.runtimeSite(site.key) else { return entry }
            var result = entry; result.site = scoped; return result
        }
    }

    @discardableResult public mutating func add(_ configuration: Configuration, target: SourceImportTarget = .automatic, name: String = "", activate: Bool = true) throws -> SourceImportResult {
        let hasVOD = !configuration.sites.isEmpty || !configuration.subscriptions.isEmpty
        let hasLive = !configuration.feeds.isEmpty || !configuration.channels.isEmpty || !configuration.subscriptions.isEmpty
        if target == .vod && !hasVOD { throw TVError.message("这个配置没有点播接口或子配置。请选择直播源类型。") }
        if target == .live && !hasLive { throw TVError.message("这个配置没有直播频道、直播订阅或子配置。请选择点播源类型。") }
        guard hasVOD || hasLive else { throw TVError.message("配置中没有可保存的内容来源。") }
        let addVOD = target != .live && hasVOD
        let shouldActivateVOD = activate && (configuration.sites.isEmpty || configuration.sites.contains(where: \.selectable) || activeVOD?.configuration.sites.contains(where: \.selectable) != true)
        // An untyped subscription list defaults to VOD. Choosing live explicitly
        // keeps its children in the live section instead.
        let addLive = target != .vod && hasLive && (target == .live || !configuration.feeds.isEmpty || !configuration.channels.isEmpty)
        let origin = configuration.location.isEmpty ? "inline:\(UUID().uuidString)" : configuration.location
        let customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if addVOD {
            if let index = vodSources.firstIndex(where: { $0.origin == origin }) {
                vodSources[index].configuration = Self.vodPayload(configuration)
                if !customName.isEmpty { vodSources[index].name = customName }
                if !configuration.sites.contains(where: { $0.id == vodSources[index].selectedSiteID && $0.selectable }) {
                    vodSources[index].selectedSiteID = configuration.sites.first(where: \.selectable)?.id ?? ""
                }
                if shouldActivateVOD { selectedVODID = vodSources[index].id }
            } else {
                let item = SavedVODSource(id: UUID().uuidString, name: customName.isEmpty ? configuration.name : customName, origin: origin, configuration: Self.vodPayload(configuration), selectedSiteID: configuration.sites.first(where: \.selectable)?.id ?? "")
                vodSources.append(item)
                if shouldActivateVOD || selectedVODID == nil { selectedVODID = item.id }
            }
        }
        if addLive {
            var candidates: [(String?, String)] = []
            var seen = Set<String>()
            for feed in configuration.feeds where seen.insert(feed.url).inserted {
                let label = customName.isEmpty ? feed.name : (configuration.feeds.count == 1 && configuration.channels.isEmpty ? customName : customName + " · " + feed.name)
                candidates.append((feed.url, label))
            }
            if !configuration.channels.isEmpty || (configuration.feeds.isEmpty && !configuration.subscriptions.isEmpty) {
                candidates.append((nil, customName.isEmpty ? configuration.name : customName))
            }
            // Refreshing a configuration removes only stale live entries from
            // that same origin; other subscriptions and the VOD selection stay.
            liveSources.removeAll { item in item.origin == origin && !candidates.contains(where: { $0.0 == item.feedURL }) }
            var firstID: String?
            for (feedURL, label) in candidates {
                if let index = liveSources.firstIndex(where: { $0.origin == origin && $0.feedURL == feedURL }) {
                    liveSources[index].configuration = Self.livePayload(configuration, feedURL: feedURL)
                    if !customName.isEmpty { liveSources[index].name = label }
                    if firstID == nil { firstID = liveSources[index].id }
                } else {
                    let item = SavedLiveSource(id: UUID().uuidString, name: label, origin: origin, configuration: Self.livePayload(configuration, feedURL: feedURL), feedURL: feedURL)
                    liveSources.append(item)
                    if firstID == nil { firstID = item.id }
                }
            }
            if activate || activeLive == nil { selectedLiveID = firstID ?? liveSources.first?.id }
        }
        normalizeSelections()
        return SourceImportResult(updatedVOD: addVOD, updatedLive: addLive)
    }

    public mutating func normalizeSelections() {
        if activeVOD == nil { selectedVODID = vodSources.first?.id }
        if activeLive == nil { selectedLiveID = liveSources.first?.id }
    }
    /// Older versions repeated every CMS interface in each live subscription.
    /// Keep source IDs and content, but retain only each entry's own payload.
    @discardableResult public mutating func compactPayloads() -> Bool {
        var changed = false
        for index in vodSources.indices {
            let old = vodSources[index].configuration
            if !old.feeds.isEmpty || !old.channels.isEmpty {
                vodSources[index].configuration = Self.vodPayload(old); changed = true
            }
        }
        for index in liveSources.indices {
            let old = liveSources[index].configuration
            let compact = Self.livePayload(old, feedURL: liveSources[index].feedURL)
            if !old.sites.isEmpty || old.feeds != compact.feeds || old.channels != compact.channels || old.subscriptions != compact.subscriptions {
                liveSources[index].configuration = compact; changed = true
            }
        }
        return changed
    }
    public var selection: SourceSelection {
        SourceSelection(vodID: selectedVODID, liveID: selectedLiveID, siteIDs: Dictionary(uniqueKeysWithValues: vodSources.map { ($0.id, $0.selectedSiteID) }))
    }
    public mutating func restoreSelection(_ selection: SourceSelection) {
        if let id = selection.vodID { _ = selectVOD(id) }
        if let id = selection.liveID { _ = selectLive(id) }
        for index in vodSources.indices {
            guard let id = selection.siteIDs[vodSources[index].id], vodSources[index].configuration.sites.contains(where: { $0.id == id && $0.selectable }) else { continue }
            vodSources[index].selectedSiteID = id
        }
        normalizeSelections()
    }
    private static func vodPayload(_ config: Configuration) -> Configuration {
        Configuration(name: config.name, location: config.location, sites: config.sites, subscriptions: config.subscriptions)
    }
    private static func livePayload(_ config: Configuration, feedURL: String?) -> Configuration {
        if let feedURL {
            return Configuration(name: config.name, location: config.location, feeds: config.feeds.filter { $0.url == feedURL })
        }
        return Configuration(name: config.name, location: config.location, channels: config.channels, subscriptions: config.subscriptions)
    }
    @discardableResult public mutating func selectVOD(_ id: String) -> Bool {
        guard vodSources.contains(where: { $0.id == id }) else { return false }; selectedVODID = id; return true
    }
    @discardableResult public mutating func selectLive(_ id: String) -> Bool {
        guard liveSources.contains(where: { $0.id == id }) else { return false }; selectedLiveID = id; return true
    }
    public mutating func selectSite(_ id: String) {
        guard let index = vodSources.firstIndex(where: { $0.id == selectedVODID }), vodSources[index].configuration.sites.contains(where: { $0.id == id && $0.selectable }) else { return }
        vodSources[index].selectedSiteID = id
    }
    public mutating func removeVOD(_ id: String) { vodSources.removeAll { $0.id == id }; normalizeSelections() }
    public mutating func removeLive(_ id: String) { liveSources.removeAll { $0.id == id }; normalizeSelections() }
    public mutating func renameVOD(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = vodSources.firstIndex(where: { $0.id == id }) else { return }; vodSources[index].name = trimmed
    }
    public mutating func renameLive(_ id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = liveSources.firstIndex(where: { $0.id == id }) else { return }; liveSources[index].name = trimmed
    }
    /// A local correction is scoped to one source, site key and exact API.
    /// Subscription refreshes preserve it; changing the source URL discards it.
    public mutating func setCSPComponent(_ component: CSPComponent?, sourceID: String, siteID: String) throws {
        guard let index = vodSources.firstIndex(where: { $0.id == sourceID }),
              let site = vodSources[index].configuration.sites.first(where: { $0.key == siteID }), site.requiresCSP else {
            throw TVError.message("未找到可修改组件的 CSP 接口，请刷新配置后重试。")
        }
        var overrides = vodSources[index].componentOverrides ?? [:]
        if let component { overrides[siteID] = CSPComponentOverride(api: site.api, component: component) }
        else { overrides.removeValue(forKey: siteID) }
        vodSources[index].componentOverrides = overrides.isEmpty ? nil : overrides
    }
    /// Replace one saved entry without importing/activating other entries from
    /// the new configuration. IDs scope history and must remain stable.
    public mutating func replaceVOD(_ id: String, configuration: Configuration, name: String) throws {
        guard let index = vodSources.firstIndex(where: { $0.id == id }) else { throw TVError.message("这个点播源已被移除，请重新打开配置管理。") }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw TVError.message("请输入源名称。") }
        guard !configuration.sites.isEmpty || !configuration.subscriptions.isEmpty else { throw TVError.message("新地址没有点播接口或子配置，原点播源已保留。") }
        guard !vodSources.contains(where: { $0.id != id && $0.origin == configuration.location }) else { throw TVError.message("这个点播地址已经存在，请选择已有的源，或使用其他地址。") }
        var updated = vodSources[index]
        if updated.origin != configuration.location { updated.componentOverrides = nil }
        updated.name = label; updated.origin = configuration.location
        updated.configuration = Self.vodPayload(configuration)
        if !configuration.sites.contains(where: { $0.id == updated.selectedSiteID && $0.selectable }) {
            updated.selectedSiteID = configuration.sites.first(where: \.selectable)?.id ?? ""
        }
        vodSources[index] = updated
    }
    public mutating func replaceLive(_ id: String, configuration: Configuration, name: String) throws {
        guard let index = liveSources.firstIndex(where: { $0.id == id }) else { throw TVError.message("这个直播源已被移除，请重新打开配置管理。") }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw TVError.message("请输入源名称。") }
        let feeds = Array(Set(configuration.feeds.map(\.url)))
        let feedURL: String?
        if feeds.count == 1 && configuration.channels.isEmpty { feedURL = feeds[0] }
        else if feeds.isEmpty && (!configuration.channels.isEmpty || !configuration.subscriptions.isEmpty) { feedURL = nil }
        else if feeds.isEmpty { throw TVError.message("新地址没有直播频道、订阅或子配置，原直播源已保留。") }
        else { throw TVError.message("新地址包含多个直播来源，请填写其中一个订阅地址，或通过“添加直播源”导入整个配置。") }
        let address = feedURL ?? configuration.location
        guard !liveSources.contains(where: { $0.id != id && ($0.feedURL ?? $0.configuration.location) == address }) else { throw TVError.message("这个直播地址已经存在，请选择已有的源，或使用其他地址。") }
        var updated = liveSources[index]
        updated.name = label; updated.origin = configuration.location
        updated.feedURL = feedURL; updated.configuration = Self.livePayload(configuration, feedURL: feedURL)
        liveSources[index] = updated
    }
}

public struct SourceSelection: Codable, Sendable {
    public var vodID: String?
    public var liveID: String?
    public var siteIDs: [String: String]
    public init(vodID: String?, liveID: String?, siteIDs: [String: String]) { self.vodID = vodID; self.liveID = liveID; self.siteIDs = siteIDs }
}
