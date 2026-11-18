import SwiftUI
import AppKit
import TVBoxCore

private enum ProbeFilter: String, CaseIterable { case all = "全部结果", success = "正常", failed = "失败", unchecked = "未完成" }
private enum ProbeSort: String, CaseIterable { case original = "原始顺序", latency = "耗时从低到高", failures = "失败优先" }

struct NetworkProbeView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: NetworkProbeModel
    @State private var filter = ProbeFilter.all
    @State private var sort = ProbeSort.latency
    @State private var search = ""
    @State private var copied = false
    private var visibleTargets: [ProbeTarget] {
        var targets = model.scopedTargets.filter { target in
            let result = model.results[target.id]
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .success: matches = result?.outcome == .success
            case .failed: matches = result?.isFailure == true
            case .unchecked: matches = result == nil || result?.outcome == .cancelled
            }
            return matches && (search.isEmpty || target.names.joined(separator: " ").localizedCaseInsensitiveContains(search) || target.displayURL.localizedCaseInsensitiveContains(search))
        }
        if sort == .latency { return ProbeRanking.ordered(targets, results: model.results) }
        if sort == .failures {
            targets.sort { lhs, rhs in
                let left = model.results[lhs.id], right = model.results[rhs.id]
                if sort == .failures, (left?.isFailure == true) != (right?.isFailure == true) { return left?.isFailure == true }
                let l = left?.outcome == .cancelled ? Int.max : (left?.milliseconds ?? Int.max)
                let r = right?.outcome == .cancelled ? Int.max : (right?.milliseconds ?? Int.max)
                return l == r ? lhs.id < rhs.id : l < r
            }
        }
        return targets
    }
    var body: some View {
        let groups = model.recommendations
        let ranks = Dictionary(uniqueKeysWithValues: groups.flatMap(\.entries).map { ($0.id, $0.rank) })
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                controls
                summary
                recommendationSection(groups)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { resultFilter; resultSearch; resultSort }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) {
                        resultFilter
                        HStack { resultSearch; Spacer(minLength: 0); resultSort }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.preparing { ProgressView(L10n.text("正在整理配置地址…")).padding() }
                else if model.targets.isEmpty {
                    EmptyViewCard(icon: "network", title: L10n.text("还没有可探测的地址"), message: L10n.text("添加点播配置或直播订阅后，可以在这里批量检查配置中的 HTTP / HTTPS 地址。"), action: L10n.text("添加内容源")) { store.showImport() }
                } else {
                    let targets = visibleTargets
                    Text(L10n.text("显示 \(targets.count) / \(model.scopedTargets.count) 个地址")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    LazyVStack(spacing: 8) {
                        ForEach(targets) { target in
                            ProbeResultRow(target: target, result: model.results[target.id], active: model.activeIDs.contains(target.id), queued: model.queuedIDs.contains(target.id), recommendation: ranks[target.id]).equatable()
                        }
                    }
                    if targets.isEmpty { Text(L10n.text("没有匹配的地址。")).foregroundStyle(Theme.muted).padding() }
                }
            }.padding(32)
        }.task { await model.prepare(store.sourceLibrary) }
        .onChange(of: model.isRunning) { running in if !running && model.completed > 0 { sort = .latency; copied = false } }
    }
    private var recommendationRanks: [String: Int] {
        Dictionary(uniqueKeysWithValues: model.recommendations.flatMap(\.entries).map { ($0.id, $0.rank) })
    }
    private var resultFilter: some View {
        Picker(L10n.text("结果筛选"), selection: $filter) {
            ForEach(ProbeFilter.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: L10n.isEnglish ? 340 : 240)
    }
    private var resultSearch: some View {
        TextField(L10n.text("搜索名称或地址"), text: $search).textFieldStyle(.roundedBorder).frame(width: 210)
    }
    private var resultSort: some View {
        Picker(L10n.text("排序"), selection: $sort) {
            ForEach(ProbeSort.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
        }.labelsHidden().frame(width: L10n.isEnglish ? 185 : 145)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("批量网络探测")).font(.system(size: 27, weight: .semibold))
                Text(L10n.text("检查配置中的点播接口、直播订阅与子配置地址。")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(copied ? L10n.text("已复制结果") : L10n.text("复制结果")) {
                let text = ProbeReport.text(targets: visibleTargets, results: model.results, recommendationRanks: recommendationRanks)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
            }.disabled(!visibleTargets.contains { model.results[$0.id] != nil })
            if model.isRunning { Button(L10n.text("停止探测")) { model.cancel() }.buttonStyle(.borderedProminent) }
            else { Button(L10n.text("开始探测")) { copied = false; model.start() }.buttonStyle(.borderedProminent).disabled(model.scopedTargets.isEmpty || model.preparing) }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("探测范围"))
                    Picker(L10n.text("探测范围"), selection: $model.kind) {
                        Text(L10n.text("全部地址")).tag(nil as ProbeTargetKind?)
                        ForEach(ProbeTargetKind.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag(Optional($0)) }
                    }.labelsHidden()
                }.frame(maxWidth: 250)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("超时"))
                    Picker(L10n.text("超时"), selection: $model.timeout) { ForEach([3, 5, 8, 10, 15], id: \.self) { Text(L10n.text("\($0) 秒")).tag($0) } }.labelsHidden()
                }.frame(width: 100)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("并发"))
                    Picker(L10n.text("并发"), selection: $model.concurrency) { ForEach([2, 4, 6, 8], id: \.self) { Text(L10n.text("\($0) 个")).tag($0) } }.labelsHidden()
                }.frame(width: 110)
            }.disabled(model.isRunning)
            HStack {
                Text(L10n.text("\(model.scopedTargets.count) 个不同地址 · 已跳过 \(model.skippedCount) 个非 HTTP 地址")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button(L10n.text("重测失败项")) { copied = false; model.start(failuresOnly: true) }.font(.system(size: 12)).disabled(model.isRunning || model.failureCount == 0)
            }
            Text(L10n.text("检测 HTTP 连接与响应，不代表接口内容有效或影片可播放。相同地址和请求头会合并；不会展开直播频道或执行爬虫。")).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.isRunning ? L10n.text("探测中 · \(model.completed) / \(model.total)") : (model.total == 0 ? L10n.text("准备就绪") : "\(L10n.string(model.stopped ? "已停止" : "已完成")) · \(model.completed) / \(model.total)")).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(L10n.text("正常 \(model.successCount)")).foregroundStyle(.green)
                Text(L10n.text("失败 \(model.failureCount)")).foregroundStyle(Theme.accent)
            }.font(.system(size: 12))
            if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(max(1, model.total))).tint(Theme.accent) }
        }
    }
    @ViewBuilder private func recommendationSection(_ groups: [ProbeRecommendationGroup]) -> some View {
        if !model.isRunning && !model.results.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.text("当前范围的网络推荐"), systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                    if model.stopped { Text(L10n.text("基于已完成的结果")).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                }
                Text(L10n.text("按各地址最近一次 HTTP 响应耗时推荐，越低越优先；只推荐 HTTP 2xx 正常响应，点播仅推荐当前版本支持的接口。实际内容和播放仍以使用为准。")).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if groups.isEmpty {
                    Text(L10n.text("暂无符合条件的推荐地址，可重测失败项或更新配置。")).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in ProbeRecommendationCard(group: group) }
                    }
                }
            }
        }
    }
}

private struct ProbeRecommendationCard: View {
    let group: ProbeRecommendationGroup
    var body: some View {
        if let first = group.entries.first {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(L10n.string(group.kind.rawValue)).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(L10n.text("首选")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.green).padding(.horizontal, 8).padding(.vertical, 4).background(Color.green.opacity(0.1), in: Capsule())
                }
                Text(first.target.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(first.result.milliseconds) ms").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.accent)
                    Text("HTTP \(first.result.statusCode ?? 200)").font(.system(size: 10)).foregroundStyle(.green)
                }
                Text(first.target.displayURL).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).textSelection(.enabled)
                if group.entries.count > 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ForEach(Array(group.entries.dropFirst())) { entry in
                        HStack(spacing: 7) {
                            Text(entry.label).foregroundStyle(Theme.accent)
                            Text(entry.target.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(entry.result.milliseconds) ms").monospacedDigit()
                        }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.2)))
        }
    }
}

private struct ProbeResultRow: View, Equatable {
    let target: ProbeTarget
    let result: ProbeResult?
    let active: Bool
    let queued: Bool
    let recommendation: Int?
    private var color: Color {
        guard let result else { return active ? Theme.accent : Theme.muted }
        switch result.outcome { case .success: return .green; case .httpError, .networkError: return Theme.accent; case .cancelled: return Theme.muted }
    }
    var body: some View {
        HStack(spacing: 16) {
            Group {
                if active { ProgressView().controlSize(.small) }
                else { Image(systemName: result == nil ? "circle.dotted" : (result?.outcome == .success ? "checkmark.circle.fill" : (result?.outcome == .cancelled ? "minus.circle" : "exclamationmark.circle"))).foregroundStyle(color) }
            }.frame(width: 20)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(target.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(L10n.string(target.kind.rawValue)).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    if target.names.count > 1 { Text(L10n.text("共 \(target.names.count) 项")).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                    if let rank = recommendation { Text(rank == 1 ? L10n.text("网络首选") : L10n.text("备选 \(rank - 1)")).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.accent) }
                    else if !target.supportedInApp { Text(L10n.text("待适配")).font(.system(size: 9)).foregroundStyle(Theme.muted) }
                }
                Text(target.displayURL).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).textSelection(.enabled)
                if let result { Text(result.message).font(.system(size: 10)).foregroundStyle(color).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                Text(statusText).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                if let result, result.outcome != .cancelled { Text("\(result.milliseconds) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted) }
            }.frame(width: 100, alignment: .trailing)
        }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
    }
    private var statusText: String {
        if active { return L10n.text("探测中") }
        if let result { return result.statusCode.map { "HTTP \($0)" } ?? (result.outcome == .cancelled ? L10n.text("已取消") : L10n.text("连接失败")) }
        return queued ? L10n.text("等待中") : L10n.text("未探测")
    }
}
