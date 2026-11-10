import Foundation

public enum ChannelGrouping: String, CaseIterable, Identifiable, Sendable {
    case automatic, original
    public var id: String { rawValue }
    public var title: String { self == .automatic ? "自动分类" : "原始分组" }
}

public struct ChannelSection: Identifiable, Sendable {
    public let name: String
    public let channels: [Channel]
    public var id: String { name }
}

/// Display-only classification. Channel identity, source groups, playback URLs
/// and guide metadata remain untouched. Names win over broad source labels.
public enum ChannelClassifier {
    public static let order = ["央视频道", "卫视频道", "影视剧场", "少儿动漫", "体育赛事", "新闻资讯", "纪录科教", "音乐综艺", "教育频道", "生活服务", "港澳台频道", "国际频道", "地方频道", "其他频道"]
    public static func category(for channel: Channel) -> String {
        category(in: channel.name) ?? category(in: channel.group) ?? "其他频道"
    }
    static func sortKey(_ name: String) -> String {
        let compact = name.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased().filter { $0.isLetter || $0.isNumber }
        // Ignore decorative prefixes for these explicitly named channel families.
        for family in ["CCTV", "CGTN"] { if let range = compact.range(of: family) { return String(compact[range.lowerBound...]) } }
        return compact
    }
    private static func category(in value: String) -> String? {
        let name = value.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased().filter { !$0.isWhitespace }
        func has(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        if has(["CCTV", "CGTN", "央视", "央視", "中央电视", "中央電視"]) || name.hasPrefix("中央") { return "央视频道" }
        if has(["卫视", "衛視"]) { return "卫视频道" }
        if has(["凤凰", "鳳凰", "翡翠", "明珠", "TVB", "TVBS", "RTHK", "HOY", "VIUTV", "東森", "东森", "中天", "民視", "民视", "三立", "八大", "台視", "台视", "華視", "华视", "中視", "中视", "澳視", "澳视", "港台", "港澳台", "香港", "澳门", "澳門", "台湾", "台灣"]) { return "港澳台频道" }
        if has(["少儿", "少兒", "儿童", "兒童", "卡通", "动漫", "動漫", "动画", "動畫", "宝宝", "寶寶", "KIDS", "CARTOON", "NICKELODEON"]) { return "少儿动漫" }
        if has(["体育", "體育", "足球", "篮球", "籃球", "网球", "網球", "高尔夫", "高爾夫", "赛车", "賽車", "赛事", "賽事", "斯诺克", "斯諾克", "SPORT", "ESPN", "NBA", "GOLF"]) { return "体育赛事" }
        if has(["电影", "電影", "影视", "影視", "剧场", "劇場", "电视剧", "電視劇", "影院", "CHC", "HBO", "MOVIE", "CINEMA", "DRAMA"]) { return "影视剧场" }
        if has(["新闻", "新聞", "资讯", "資訊", "NEWS", "CNN", "BBCWORLD", "ALJAZEERA"]) { return "新闻资讯" }
        if has(["纪录", "紀錄", "纪实", "紀實", "科教", "探索", "地理", "DISCOVERY", "NATIONALGEOGRAPHIC", "DOCUMENTARY"]) { return "纪录科教" }
        if has(["音乐", "音樂", "综艺", "綜藝", "戏曲", "戲曲", "戏剧", "戲劇", "演唱", "MTV", "MUSIC"]) { return "音乐综艺" }
        if has(["教育", "课堂", "課堂", "教学", "教學", "CETV"]) { return "教育频道" }
        if has(["生活", "购物", "購物", "美食", "旅游", "旅遊", "健康", "养生", "養生", "农业", "農業", "乡村", "鄉村"]) { return "生活服务" }
        if has(["国际", "國際", "境外", "BBC", "NHK", "KBS", "ARIRANG", "FRANCE24", "TV5MONDE", "FOX", "ABC", "NBC", "CBS"]) { return "国际频道" }
        if has(["地方", "综合", "綜合", "都市", "公共", "北京", "上海", "天津", "重庆", "重慶", "河北", "河南", "山东", "山東", "山西", "陕西", "陝西", "江苏", "江蘇", "浙江", "安徽", "福建", "江西", "湖北", "湖南", "广东", "廣東", "广西", "廣西", "海南", "四川", "贵州", "貴州", "云南", "雲南", "辽宁", "遼寧", "吉林", "黑龙江", "黑龍江", "甘肃", "甘肅", "青海", "宁夏", "寧夏", "内蒙古", "內蒙古", "新疆", "西藏"]) { return "地方频道" }
        return nil
    }
}
