import AppKit
import SwiftUI
import Combine
import Sparkle
import TVBoxCore

@MainActor final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status = L10n.text("尚未检查更新")
    @Published private(set) var availableVersion: String?
    @Published private(set) var readyOnQuit = false
    @Published var confirmImmediateInstall = false
    let configuration: ApplicationUpdateConfiguration?
    private let feedOverride: URL?
    private var controller: SPUStandardUpdaterController?
    private var installAndRelaunch: (() -> Void)?

    init(bundle: Bundle = .main, enabled: Bool = true, validationFeed: URL? = nil) {
        configuration = try? ApplicationUpdateConfiguration(repository: bundle.object(forInfoDictionaryKey: "TVBoxUpdateRepository") as? String ?? "", publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
        // Only isolated validation bundles can supply a local test feed. The
        // released application's update location is fixed by its repository.
        if let validationFeed {
            precondition(bundle.bundleIdentifier?.hasPrefix("local.tvboxmac.validation.") == true && validationFeed.scheme == "http" && validationFeed.host == "127.0.0.1")
        }
        feedOverride = validationFeed
        super.init()
        guard enabled else { status = L10n.text("测试模式下关闭更新检查"); return }
        guard configuration != nil else { status = L10n.text("此安装包未配置更新服务，请使用正式发布版本。"); return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        do { try updater.start() }
        catch { status = L10n.text("更新组件未能启动，请使用正式发布版本。"); self.controller = nil }
    }
    func checkForUpdates() {
        if readyOnQuit, installAndRelaunch != nil { confirmImmediateInstall = true; return }
        guard canCheckForUpdates, let controller else { return }
        if !readyOnQuit { status = L10n.text("正在检查新版本…") }
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setAutomaticDownloads(_ value: Bool) { controller?.updater.automaticallyDownloadsUpdates = value }
    func installPreparedUpdate() {
        confirmImmediateInstall = false
        guard readyOnQuit else { return }
        installAndRelaunch?()
    }
    func checkInBackground() { controller?.updater.checkForUpdatesInBackground() }
    func feedURLString(for updater: SPUUpdater) -> String? { (feedOverride ?? configuration?.feedURL())?.absoluteString }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = L10n.text("发现新版本 \(item.displayVersionString)")
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        switch reason {
        case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue): status = L10n.text("当前已是最新版本")
        case Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue): status = L10n.text("当前版本比已发布的正式版更新")
        case Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue), Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue), Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue): status = L10n.text("暂无适用于当前 macOS 或处理器的新版本")
        default: status = L10n.text("暂无可安装的新版本")
        }
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { status = L10n.text("更新已下载，正在校验…") }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyOnQuit = true
        installAndRelaunch = immediateInstallHandler
        status = L10n.text("更新已准备好，将在退出 TVBox 时安装。")
        // Own the pending cycle: do not allow an impatient scheduled reminder
        // to request a restart during video playback. Sparkle still installs
        // on ordinary quit; an immediate restart requires the user's action.
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.code == SUError.noUpdateError.rawValue { return }
        readyOnQuit = false; confirmImmediateInstall = false; installAndRelaunch = nil
        if failure.code == SUError.installationCanceledError.rawValue { status = L10n.text("已取消更新，可稍后重试。"); return }
        status = L10n.text("暂时无法检查或安装更新，请检查网络后重试。")
    }
}

struct AppUpdateConfirmation: ViewModifier {
    @ObservedObject var updates: AppUpdateController
    func body(content: Content) -> some View {
        content.confirmationDialog(L10n.text("安装更新并重新启动 TVBox？"), isPresented: $updates.confirmImmediateInstall, titleVisibility: .visible) {
            Button(L10n.text("安装并重启")) { updates.installPreparedUpdate() }
            Button(L10n.text("稍后"), role: .cancel) { }
        } message: {
            Text(L10n.text("当前播放将结束，播放进度会保存。也可以稍后退出 TVBox 时自动安装。"))
        }
    }
}

struct AppUpdateView: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text("软件更新"), systemImage: "arrow.triangle.2.circlepath").font(.system(size: 17, weight: .semibold))
                    Text(L10n.text("当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.string("开发版"))"))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(updates.readyOnQuit ? L10n.text("安装并重启…") : L10n.text("检查更新…")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates && !updates.readyOnQuit).buttonStyle(.borderedProminent)
            }
            Divider().overlay(Theme.line)
            Toggle(L10n.text("自动检查新版本（每天）"), isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
                .disabled(updates.configuration == nil)
            Toggle(L10n.text("自动下载更新，退出 TVBox 时安装"), isOn: Binding(get: { updates.automaticallyDownloads }, set: updates.setAutomaticDownloads))
                .disabled(updates.configuration == nil || !updates.automaticallyChecks)
            Text(updates.status).font(.system(size: 12)).foregroundStyle(updates.readyOnQuit ? Theme.accent : Theme.muted)
            HStack(spacing: 8) {
                if let date = updates.lastChecked { Text(L10n.text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")) }
                Spacer()
                if let url = updates.configuration?.releasesURL { Link(L10n.text("版本记录"), destination: url) }
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(22).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11))
    }
}

struct CheckForAppUpdatesMenu: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View { Button(L10n.text("检查更新…")) { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates && !updates.readyOnQuit) }
}
