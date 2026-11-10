import Foundation

/// Unwraps configuration transport formats; it never loads or executes spiders.
public enum ConfigurationPayload {
    public static func decode(_ data: Data) throws -> Data {
        guard data.count < 16 * 1024 * 1024 else { throw TVError.message("配置内容超过 16 MB。") }
        var payload = removingBOM(data)
        for _ in 0..<3 {
            let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("#EXTM3U") { return payload }
            if isImage(payload) {
                guard let marker = payload.range(of: Data("**".utf8), options: .backwards),
                      let decoded = base64(Data(payload[marker.upperBound...])) else {
                    throw TVError.message("地址返回了图片，但图片后没有可识别的配置数据。请使用配置接口地址。")
                }
                payload = removingBOM(decoded)
                continue
            }
            // Some providers distribute the same **Base64 envelope as text.
            if let text, !text.hasPrefix("<"), let marker = text.range(of: "**", options: .backwards),
               let decoded = base64(Data(text[marker.upperBound...].utf8)), looksLikeConfiguration(decoded) {
                payload = removingBOM(decoded); continue
            }
            if let decoded = base64(payload), looksLikeConfiguration(decoded) {
                payload = removingBOM(decoded); continue
            }
            return payload
        }
        guard !isImage(payload) else { throw TVError.message("配置封装层数过多，暂时无法读取。") }
        return payload
    }

    private static func removingBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    }
    private static func isImage(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) || data.starts(with: [0x42, 0x4D])
    }
    private static func looksLikeConfiguration(_ data: Data) -> Bool {
        guard let text = String(data: removingBOM(data), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("#EXTM3U")
    }
    private static func base64(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        // Permit omitted padding, but reject arbitrary non-Base64 characters.
        let remainder = compact.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { compact += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: compact)
    }
}
