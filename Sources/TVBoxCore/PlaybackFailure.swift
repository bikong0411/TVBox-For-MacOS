import Foundation

/// Classifies nested AVFoundation/URL loading errors without logging URLs or headers.
public struct PlaybackFailure: Equatable {
    public enum Kind: String { case tls, certificate, authentication, unavailable, network, playback }
    public let kind: Kind
    public let title: String
    public let message: String
    public let diagnostic: String

    public init(error: Error?, mediaStatusCodes: [Int] = []) {
        if let remux = error as? LiveRemuxFailure {
            kind = remux.kind == .timeout ? .network : .playback
            title = remux.kind == .invalidInput ? "直播线路数据无效" : (remux.kind == .unsupportedCodec ? "此线路编码暂不支持" : "直播线路无法播放")
            message = remux.localizedDescription; diagnostic = remux.diagnostic; return
        }
        var errors: [NSError] = []
        var current = error as NSError?
        var visited = Set<ObjectIdentifier>()
        while let item = current, errors.count < 8, visited.insert(ObjectIdentifier(item)).inserted {
            errors.append(item)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let urlCodes = Set(errors.filter { $0.domain == NSURLErrorDomain || $0.domain == "kCFErrorDomainCFNetwork" }.map(\.code))
        let certificateCodes = Set([
            URLError.serverCertificateHasBadDate.rawValue,
            URLError.serverCertificateNotYetValid.rawValue,
            URLError.serverCertificateHasUnknownRoot.rawValue,
            URLError.serverCertificateUntrusted.rawValue
        ])
        if !urlCodes.isDisjoint(with: certificateCodes) {
            kind = .certificate
            title = "片源证书校验失败"
            message = "片源服务器的 HTTPS 证书未通过校验。请确认设备日期正确；仍失败时，需要片源维护者更新有效证书。"
        } else if urlCodes.contains(URLError.secureConnectionFailed.rawValue) || urlCodes.contains(URLError.appTransportSecurityRequiresSecureConnection.rawValue) {
            kind = .tls
            title = "暂时连接不上片源"
            message = "未能与视频服务器建立安全连接。请稍后再试，或切换其他线路；如果一直出现，请联系片源提供者检查服务器。"
        } else if urlCodes.contains(URLError.clientCertificateRequired.rawValue) || urlCodes.contains(URLError.clientCertificateRejected.rawValue) || urlCodes.contains(URLError.userAuthenticationRequired.rawValue) || mediaStatusCodes.contains(401) || mediaStatusCodes.contains(403) {
            kind = .authentication
            title = "片源拒绝访问"
            message = "服务器要求授权或拒绝了请求。请检查配置中的访问权限和请求头，播放地址也可能已经过期。"
        } else if mediaStatusCodes.contains(404) || mediaStatusCodes.contains(410) || urlCodes.contains(URLError.fileDoesNotExist.rawValue) || urlCodes.contains(URLError.resourceUnavailable.rawValue) {
            kind = .unavailable
            title = "视频地址已失效"
            message = "服务器找不到这段视频。请刷新片源详情，或选择仍然有效的播放地址。"
        } else if !urlCodes.isDisjoint(with: [URLError.timedOut.rawValue, URLError.notConnectedToInternet.rawValue, URLError.cannotFindHost.rawValue, URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue, URLError.dnsLookupFailed.rawValue]) {
            kind = .network
            title = "无法连接视频服务器"
            message = "连接超时、域名解析失败或网络已断开。请检查网络后重试。"
        } else if errors.contains(where: { $0.domain == "mpv" && $0.code == -17 }) {
            kind = .playback
            title = "暂时无法播放"
            message = "播放器无法识别返回的内容。若这是播放网页，请在浏览器打开，或使用视频直链。"
        } else {
            kind = .playback
            title = "暂时无法播放"
            message = "播放器未能读取有效的视频。请重试或切换线路；仍然失败时，请刷新片源地址。"
        }
        let chain = errors.map { "\($0.domain) (\($0.code))" }.joined(separator: " → ")
        let statuses = mediaStatusCodes.isEmpty ? "" : "媒体状态：" + mediaStatusCodes.map(String.init).joined(separator: ", ")
        diagnostic = [chain, statuses].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
