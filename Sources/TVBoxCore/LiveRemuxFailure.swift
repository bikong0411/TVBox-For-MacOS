import Foundation

/// Structured helper errors; only a fixed step name and numeric code reach diagnostics.
public struct LiveRemuxFailure: Error, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable { case invalidInput, unsupportedCodec, timeout, processing }
    public let kind: Kind
    public let diagnostic: String
    public init(log: String) {
        let steps = ["INPUT_OPEN", "STREAM_INFO", "OUTPUT_CREATE", "VIDEO_CODEC_NOT_SUPPORTED", "NO_SUPPORTED_STREAM", "OUTPUT_HEADER", "WRITE_SEGMENT", "READ_STREAM"]
        let lines = log.split(separator: "\n")
        diagnostic = lines.compactMap { line -> String? in
            for step in steps {
                guard line.hasPrefix(step + " ("), let close = line.firstIndex(of: ")") else { continue }
                let start = line.index(line.startIndex, offsetBy: step.count + 2)
                guard let code = Int(line[start..<close]) else { continue }
                return "\(step) (\(code))"
            }
            return nil
        }.suffix(4).joined(separator: " → ")
        if diagnostic.contains("VIDEO_CODEC_NOT_SUPPORTED") || diagnostic.contains("NO_SUPPORTED_STREAM") { kind = .unsupportedCodec }
        else if diagnostic.contains("INPUT_OPEN (-1094995529)") { kind = .invalidInput }
        else { kind = .processing }
    }
    public init(timeout: Bool) { kind = timeout ? .timeout : .processing; diagnostic = timeout ? "REMUX_TIMEOUT" : "REMUX_FAILED" }
    public var errorDescription: String? {
        switch kind {
        case .invalidInput: return "此线路返回的数据无法识别为受支持的视频，可能是失效链接、网页或未支持的格式。请更换线路或刷新直播源。"
        case .unsupportedCodec: return "此线路的音视频编码暂不支持直接封装，请更换线路或使用其他播放器。"
        case .timeout: return "连接直播超时，未收到可播放的音视频数据。"
        case .processing: return "此线路的直播兼容处理失败，请更换线路或刷新直播源。"
        }
    }
}
