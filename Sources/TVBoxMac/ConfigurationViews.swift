import SwiftUI
import TVBoxCore

struct ImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var address = ""
    @State private var sourceName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Image(systemName: "square.and.arrow.down").font(.system(size: 24)).foregroundStyle(Theme.accent); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(store.importing).keyboardShortcut(.cancelAction) }
            VStack(alignment: .leading, spacing: 9) {
                Text("添加内容来源").font(.system(size: 27, weight: .semibold))
                Text("输入 TVBox JSON 配置地址，或导入 M3U / TXT 直播列表。").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Picker("导入类型", selection: $store.importTarget) {
                ForEach(SourceImportTarget.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(store.importing)
            TextField("源名称（可选）", text: $sourceName).textFieldStyle(.roundedBorder).disabled(store.importing)
            VStack(alignment: .leading, spacing: 9) {
                Text("配置地址").font(.system(size: 12, weight: .medium))
                TextField("https://example.com/tvbox.json", text: $address).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8)).onSubmit { submit() }.disabled(store.importing)
            }
            if let error = store.importError { ErrorBanner(message: error) }
            HStack(spacing: 8) { Image(systemName: "info.circle"); Text("新地址会追加保存；同一地址会更新。点播源与直播源分别选择，互不覆盖。").fixedSize(horizontal: false, vertical: true) }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            HStack {
                Button("选择本地文件…") { let target = store.importTarget; dismiss(); store.importFile(target: target, name: sourceName) }.disabled(store.importing)
                Spacer()
                if store.importing { ProgressView().controlSize(.small) }
                Button(store.importing ? "正在导入…" : "导入配置") { submit() }.buttonStyle(.borderedProminent).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.importing).keyboardShortcut(.defaultAction)
            }
        }.padding(32).frame(width: 540).background(Theme.background).tint(Theme.accent).interactiveDismissDisabled(store.importing)
            .onAppear { store.importError = nil }
    }
    private func submit() { guard !store.importing else { return }; let target = store.importTarget; Task { await store.importURL(address, target: target, name: sourceName) } }
}

struct DirectView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("打开视频地址").font(.system(size: 24, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction) }
            Text("支持 HLS / MP4 等系统可播放的视频直链。").font(.system(size: 12)).foregroundStyle(Theme.muted)
            TextField("https://example.com/video.m3u8", text: $address).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8)).onSubmit { submit() }
            HStack { Button("打开本地视频…") { dismiss(); store.openVideoFile() }; Spacer(); Button("播放") { submit() }.buttonStyle(.borderedProminent).disabled(address.isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(32).frame(width: 540).background(Theme.background).tint(Theme.accent)
    }
    private func submit() { if store.playDirect(address) { dismiss() } }
}

