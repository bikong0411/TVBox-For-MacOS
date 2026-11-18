import SwiftUI
import AppKit
import TVBoxCore

struct CastingPicker: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var surface: PersistentVideoSurface
    @ObservedObject var casting: DLNACastingController
    var onPresentationChange: (Bool) -> Void
    @State private var presented = false
    @State private var appleTV = false
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 4) {
                PlayerControlIcon(name: "airplayvideo")
                Text(casting.connected || controller.airPlayConnected ? L10n.text("投屏中") : controller.airPlayPreparing ? L10n.text("连接中") : L10n.text("投屏"))
                    .font(.system(size: 11, weight: .medium))
            }.foregroundStyle(casting.connected || controller.airPlayConnected ? Theme.accent : .white)
        }.help(L10n.text("投屏到安卓电视（DLNA）或 Apple TV（AirPlay）"))
        .popover(isPresented: $presented, arrowEdge: .top) {
            CastingPanel(controller: controller, surface: surface, casting: casting, appleTV: $appleTV) { active in
                onPresentationChange(active || presented)
            }
        }
        .onChange(of: presented) { showing in
            onPresentationChange(showing)
            if showing { if appleTV { casting.searchAirPlay() } else { casting.search() } }
            else { casting.stopSearch() }
        }
        .onChange(of: appleTV) { apple in
            if apple {
                casting.stopSearch(); casting.searchAirPlay()
            } else { casting.search() }
        }
        .onDisappear { casting.stopSearch(); onPresentationChange(false) }
    }
}

/// A bounded viewport gives the popover a definite size. All variable content
/// shares one scroll view, so long messages cannot squeeze the device list out.
struct CastingPanel: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var surface: PersistentVideoSurface
    @ObservedObject var casting: DLNACastingController
    @Binding var appleTV: Bool
    var onPresentationChange: (Bool) -> Void
    private var viewportHeight: CGFloat {
        min(420, max(120, (NSScreen.main?.visibleFrame.height ?? 800) - 160))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("投屏到电视")).font(.system(size: 16, weight: .semibold))
                Picker(L10n.text("电视类型"), selection: $appleTV) {
                    Text(L10n.text("安卓电视 · DLNA")).tag(false)
                    Text(L10n.text("AirPlay 电视")).tag(true)
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(18)
            Divider().overlay(Theme.line)
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if appleTV {
                    Text(L10n.text("Mac 和电视需连接同一网络，并在电视上开启 AirPlay。首次连接请确认电视上的配对码。"))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        AirPlayRoutePicker(player: controller.player) { active in
                            if active { controller.prepareAirPlayRoute() }
                            onPresentationChange(active)
                        }.frame(width: 36, height: 36)
                        Text(controller.airPlayConnected ? L10n.text("正在通过 AirPlay 播放") : controller.airPlayPreparing ? L10n.text("正在准备 AirPlay 视频…") : L10n.text("系统 AirPlay"))
                    }.disabled(!controller.ready || casting.selectedDevice != nil)
                    if casting.selectedDevice != nil {
                        Text(L10n.text("请先结束当前电视投屏，再使用系统 AirPlay。")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(controller.airPlayMessage ?? L10n.text("选中设备后切换播放通道；选择“此 Mac”可结束投屏。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let diagnostic = controller.airPlayDiagnostic {
                        DisclosureGroup(L10n.text("错误详情")) { Text(diagnostic).font(.caption).textSelection(.enabled) }
                    }
                    if controller.airPlayPreparing { Button(L10n.text("取消 AirPlay 准备")) { controller.cancelAirPlayPreparation() } }
                    Divider()
                    HStack {
                        Text(L10n.text("兼容连接")).font(.callout.weight(.medium))
                        Spacer()
                        if casting.airPlaySearching { ProgressView().controlSize(.small) }
                        Button(L10n.text("重新搜索")) { casting.searchAirPlay() }.disabled(casting.airPlaySearching)
                    }
                    Text(L10n.text("系统 AirPlay 播放失败时，请选择下方电视。投屏期间保持 Mac 在线。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if casting.airPlayDevices.isEmpty {
                        Text(casting.airPlaySearching ? L10n.text("正在搜索同一网络中的兼容电视…") : L10n.text("未找到兼容连接。需要配对的设备请使用上方系统 AirPlay。"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) { ForEach(casting.airPlayDevices) { device in deviceRow(device) } }
                    }
                    if let device = casting.selectedDevice, device.isAirPlayVideo {
                        Text(casting.error ?? casting.status).font(.caption).foregroundStyle(.secondary)
                        Button(casting.connecting ? L10n.text("取消投屏") : L10n.text("返回本机播放")) { controller.returnToLocal() }
                        Text(L10n.text("音量请使用电视遥控器调整。")).font(.caption).foregroundStyle(.secondary)
                    } else if let error = casting.error { Text(error).font(.caption).foregroundStyle(Theme.accent) }
                } else {
                    HStack {
                        Text(casting.searching ? L10n.text("正在搜索同一网络中的电视…") : L10n.text("可用设备")).font(.callout)
                        Spacer()
                        if casting.searching { ProgressView().controlSize(.small) }
                        Button(L10n.text("重新搜索")) { casting.search() }.disabled(casting.searching)
                    }
                    if casting.devices.isEmpty {
                        Text(casting.searching ? L10n.text("搜索大约需要几秒钟。") : L10n.text("没有找到电视。请确认连接同一 Wi-Fi，并在电视上开启 DLNA / 多屏互动。"))
                            .foregroundStyle(.secondary).font(.callout).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                    } else {
                        VStack(spacing: 6) { ForEach(casting.devices) { device in deviceRow(device) } }
                    }
                    if !controller.ready { Text(L10n.text("视频连接成功后即可投屏。设备搜索可提前进行。")).font(.caption).foregroundStyle(.secondary) }
                    if surface.externalPlaybackActive { Text(L10n.text("请先在 AirPlay 中选择“此 Mac”，再使用 DLNA。")).font(.caption).foregroundStyle(.secondary) }
                    if let error = casting.error { Text(error).font(.callout).foregroundStyle(Theme.accent) }
                    if casting.selectedDevice != nil {
                        Text(casting.status).font(.caption).foregroundStyle(.secondary)
                        Button(casting.connecting ? L10n.text("取消投屏") : L10n.text("返回本机播放")) { controller.returnToLocal() }
                    }
                    Text(L10n.text("投屏期间请保持 Mac 在线。MP4、HLS 的兼容性较好，具体格式由电视决定。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12)).lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
            }.scrollIndicators(.visible).frame(height: viewportHeight)
        }
        .frame(width: 400)
        .foregroundStyle(.white).tint(Theme.accent)
        .background(Theme.background).preferredColorScheme(.dark)
    }
    private func deviceRow(_ device: DLNADevice) -> some View {
        Button { controller.cast(to: device) } label: {
            HStack {
                Image(systemName: device.isAirPlayVideo ? "airplayvideo" : "tv")
                Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer()
                if casting.selectedDevice?.id == device.id {
                    if casting.connecting { ProgressView().controlSize(.small) }
                    else if casting.connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                }
            }.padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!controller.ready || surface.externalPlaybackActive || casting.connecting)
    }
}

struct DLNAPlaybackStatus: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var casting: DLNACastingController
    var body: some View {
        if let device = casting.selectedDevice {
            VStack(spacing: 10) {
                if casting.connecting { ProgressView() } else { Image(systemName: "tv").font(.title2) }
                Text(device.name).font(.headline)
                Text(device.isAirPlayVideo ? L10n.text("AirPlay · 兼容连接") : "DLNA").font(.caption).foregroundStyle(.secondary)
                Text(casting.error ?? casting.status).font(.callout).multilineTextAlignment(.center)
                Button(casting.connecting ? L10n.text("取消投屏") : L10n.text("返回本机播放")) { controller.returnToLocal() }
            }.padding(22).frame(maxWidth: 350)
                .foregroundStyle(.white).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct PlaybackConnectionStatus: View {
    @ObservedObject var controller: PlayerController
    var onCancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(controller.connectionStartedAt)))
            VStack(spacing: 11) {
                ProgressView().controlSize(.regular)
                Text(controller.connectingMessage).font(.system(size: 14, weight: .medium))
                Text(elapsed >= 8 ? L10n.text("片源响应较慢，仍在尝试连接 · \(elapsed) 秒") : L10n.text("首次加载可能需要几秒钟"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                Button(L10n.text("取消播放"), action: onCancel).font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }.padding(22).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
