import Foundation

public enum ProbeReport {
    public static func text(targets: [ProbeTarget], results: [String: ProbeResult], recommendationRanks: [String: Int] = [:]) -> String {
        func field(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let formatter = ISO8601DateFormatter()
        var rows = ["名称\t类型\t地址\tHTTP状态\t耗时(ms)\t网络推荐\t结果\t时间"]
        for target in targets {
            guard let result = results[target.id] else { continue }
            let recommendation = recommendationRanks[target.id].map { $0 == 1 ? "首选" : "备选 \($0 - 1)" } ?? ""
            rows.append([target.names.joined(separator: " / "), target.kind.rawValue, target.displayURL, result.statusCode.map(String.init) ?? "", result.outcome == .cancelled ? "" : String(result.milliseconds), recommendation, result.message, formatter.string(from: result.checkedAt)].map(field).joined(separator: "\t"))
        }
        return rows.joined(separator: "\n")
    }
}
