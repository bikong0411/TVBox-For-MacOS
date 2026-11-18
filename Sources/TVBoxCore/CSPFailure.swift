import Foundation

public enum CSPFailure: Error, LocalizedError, Equatable, Sendable {
    case componentChecksumMismatch
    case refreshedChecksumMismatch
    case localComponentMismatch
    case interfaceChanged
    case entryClassMissing

    public var errorDescription: String? {
        switch self {
        case .componentChecksumMismatch: return "爬虫组件校验失败，文件可能已更新，请刷新源配置。"
        case .refreshedChecksumMismatch: return "已刷新原始订阅，但组件与校验值仍不一致。来源可能尚未同步，请稍后重试。"
        case .localComponentMismatch: return "本机指定的组件校验失败。请在配置管理中更新修正组件，或恢复源配置提供的组件。"
        case .interfaceChanged: return "原始订阅中的此接口已移除或更换。请刷新配置后重新选择接口。"
        case .entryClassMissing: return "爬虫入口不存在：所选接口不在此配置提供的组件中。若使用合并源，请切换到原始仓库，再选择接口。"
        }
    }
}
