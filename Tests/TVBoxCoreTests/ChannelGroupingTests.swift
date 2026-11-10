import Foundation
import Testing
@testable import TVBoxCore

@Suite struct ChannelGroupingTests {
    private func channel(_ name: String, group: String = "未分组", suffix: String = "") -> Channel {
        Channel(name: name, group: group, urls: ["https://fixture.invalid/" + (name + suffix).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!])
    }
    @Test func channelFamiliesAndQualityVariantsShareCategories() {
        for name in ["CCTV1 综合", "cctv-1 HD", "ＣＣＴＶ５+ UHD", "央视纪录", "央視綜合", "中央三套", "CGTN Documentary"] {
            #expect(ChannelClassifier.category(for: channel(name)) == "央视频道")
        }
        for name in ["湖南卫视", "浙江衛視高清", "北京卫视 4K"] { #expect(ChannelClassifier.category(for: channel(name)) == "卫视频道") }
        #expect(ChannelClassifier.category(for: channel("TVB 翡翠台")) == "港澳台频道")
        #expect(ChannelClassifier.category(for: channel("凤凰资讯")) == "港澳台频道")
    }
    @Test func contentCategoriesAndSourceFallbackArePredictable() {
        let samples = ["CHC家庭影院": "影视剧场", "金鹰卡通": "少儿动漫", "广东体育 HD": "体育赛事", "BBC World News": "新闻资讯", "Discovery探索": "纪录科教", "经典音乐": "音乐综艺", "CETV1": "教育频道", "健康生活": "生活服务", "NHK World": "国际频道", "上海都市": "地方频道", "自定义频道": "其他频道"]
        for (name, category) in samples { #expect(ChannelClassifier.category(for: channel(name)) == category) }
        #expect(ChannelClassifier.category(for: channel("高清一台", group: "少儿频道")) == "少儿动漫")
        #expect(ChannelClassifier.category(for: channel("足球直播", group: "综合频道")) == "体育赛事")
    }
    @Test func groupingIsLosslessAndDoesNotMergeSimilarChannelNames() {
        var first = channel("CCTV1", group: "原始A")
        first.guide = LiveGuideInfo(url: "https://fixture.invalid/epg", channelID: "c1", catchup: CatchupTemplate(source: "https://fixture.invalid/{utc}"))
        first.headers = ["Authorization": "fixture-only"]
        let input = [channel("未知频道"), channel("CCTV1 高清", group: "原始B"), first, channel("湖南卫视")]
        let index = ChannelIndex(channels: input)
        let sections = index.sections(), flattened = sections.flatMap(\.channels)
        #expect(sections.map(\.name) == ["央视频道", "卫视频道", "其他频道"])
        #expect(sections[0].channels.map(\.name) == ["CCTV1", "CCTV1 高清"])
        #expect(Set(flattened.map(\.id)) == Set(index.channels.map(\.id)))
        #expect(flattened.count == index.channels.count && index.routeCount == 4)
        #expect(flattened.first(where: { $0.id == first.id }) == first)
        #expect(index.channels.map(\.id) == input.map(\.id))
        #expect(index.sections(grouping: .original).first(where: { $0.name == "原始A" })?.channels == [first])
    }
    @Test func groupAndSearchIntersectWithoutEmptySections() {
        let index = ChannelIndex(channels: [channel("CCTV1"), channel("CCTV5"), channel("CHC高清电影"), channel("体育高清"), channel("未识别频道")])
        #expect(index.sections(group: "央视频道", query: "5").flatMap(\.channels).map(\.name) == ["CCTV5"])
        #expect(index.sections(query: "高清").map(\.name) == ["影视剧场", "体育赛事"])
        #expect(index.sections(group: "央视频道", query: "CHC").isEmpty)
        #expect(index.sections(group: "不存在").isEmpty)
        #expect(index.count(group: "全部", grouping: .automatic) == 5)
        #expect(index.count(group: "央视频道", grouping: .automatic) == 2)
        #expect(index.automaticGroups == ["全部", "央视频道", "影视剧场", "体育赛事", "其他频道"])
    }
    @Test func originalGroupNamedAllAndDifferentAuthorizationRemainVisible() {
        var one = channel("CCTV1", group: "全部"), two = one
        one.headers = ["Authorization": "A"]; two.headers = ["Authorization": "B"]
        let index = ChannelIndex(channels: [one, two, channel("电影频道", group: "另一个组")])
        for mode in ChannelGrouping.allCases {
            let items = index.sections(grouping: mode).flatMap(\.channels)
            #expect(items.count == 3 && Set(items.map(\.id)).count == 3)
        }
        #expect(index.sections(grouping: .original).first { $0.name == "全部" }?.channels.count == 2)
    }
    @Test func largeCatalogueIsIndexedOnceAndGroupOrderStaysStable() {
        let input = (0..<6000).map { channel($0.isMultiple(of: 2) ? "CCTV\($0)" : "体育\($0)") }
        let index = ChannelIndex(channels: input)
        #expect(index.automaticGroups == ["全部", "央视频道", "体育赛事"])
        #expect(index.matching(group: "体育赛事", grouping: .automatic).count == 3000)
        #expect(index.sections().flatMap(\.channels).count == 6000)
        #expect(index.matching(query: "cCtV100", grouping: .automatic).map(\.name) == ["CCTV100", "CCTV1000", "CCTV1002", "CCTV1004", "CCTV1006", "CCTV1008"])
    }
    @Test func similarNamesAreAdjacentAndChannelNumbersSortNaturally() {
        let input = ["CCTV10", "CCTV2", "CCTV-1高清", "[超清]CCTV1", "CCTV1"].map { channel($0) }
        let index = ChannelIndex(channels: input)
        let ordered = index.matching(grouping: .automatic).map(\.name)
        #expect(Set(ordered.prefix(3)) == Set(["CCTV-1高清", "[超清]CCTV1", "CCTV1"]))
        #expect(Array(ordered.suffix(2)) == ["CCTV2", "CCTV10"])
        #expect(index.matching().map(\.name) == input.map(\.name))
    }
}
