import SwiftUI
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
                Text(casting.connected || surface.externalPlaybackActive ? "投屏中" : "投屏")
                    .font(.system(size: 11, weight: .medium))
            }.foregroundStyle(casting.connected || surface.externalPlaybackActive ? Theme.accent : .white)
        }.help("投屏到安卓电视（DLNA）或 Apple TV（AirPlay）")
        .popover(isPresented: $presented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                Text("投屏到电视").font(.headline)
                Picker("电视类型", selection: $appleTV) {
                    Text("安卓电视 · DLNA").tag(false)
                    Text("Apple TV · AirPlay").tag(true)
                }.pickerStyle(.segmented)
                if appleTV {
                    Text("Mac 与 Apple TV 连接同一网络，点击下方图标选择设备；首次连接请在电视上确认配对码。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        AirPlayRoutePicker(player: controller.player) { active in
                            if active { controller.prepareAirPlayRoute() }
                            onPresentationChange(active || presented)
                        }.frame(width: 36, height: 36)
                        Text(surface.externalPlaybackActive ? "正在通过 AirPlay 播放" : "选择 AirPlay 设备")
                    }.disabled(!controller.ready || casting.selectedDevice != nil)
                    if casting.selectedDevice != nil {
                        Text("请先结束 DLNA 投屏，再选择 AirPlay 设备。").font(.caption).foregroundStyle(.secondary)
                        Button("结束 DLNA 投屏") { controller.returnToLocal() }
                    }
                    Text(controller.airPlayMessage ?? "选择设备后才切换播放通道。选择“此 Mac”可结束 AirPlay。")
                        .font(.caption).foregroundStyle(.secondary)
                    if controller.airPlayPreparing { Button("取消 AirPlay 准备") { controller.cancelAirPlayPreparation() } }
                } else {
                    HStack {
                        Text(casting.searching ? "正在搜索同一网络中的电视…" : "可用设备").font(.callout)
                        Spacer()
                        if casting.searching { ProgressView().controlSize(.small) }
                        Button("重新搜索") { casting.search() }.disabled(casting.searching)
                    }
                    if casting.devices.isEmpty {
                        Text(casting.searching ? "搜索大约需要几秒钟。" : "没有找到电视。请确认连接同一 Wi-Fi，并在电视上开启 DLNA / 多屏互动。")
                            .foregroundStyle(.secondary).font(.callout).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(casting.devices) { device in
                                    Button {
                                        controller.cast(to: device)
                                    } label: {
                                        HStack {
                                            Image(systemName: "tv")
                                            Text(device.name).lineLimit(2)
                                            Spacer()
                                            if casting.selectedDevice?.id == device.id {
                                                if casting.connecting { ProgressView().controlSize(.small) }
                                                else if casting.connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                                            }
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).disabled(!controller.ready || surface.externalPlaybackActive || casting.connecting)
                                }
                            }
                        }.frame(maxHeight: 180)
                    }
                    if !controller.ready { Text("视频连接成功后即可投屏。设备搜索可提前进行。").font(.caption).foregroundStyle(.secondary) }
                    if surface.externalPlaybackActive { Text("请先在 AirPlay 中选择“此 Mac”，再使用 DLNA。").font(.caption).foregroundStyle(.secondary) }
                    if let error = casting.error { Text(error).font(.callout).foregroundStyle(Theme.accent) }
                    if casting.selectedDevice != nil {
                        Text(casting.status).font(.caption).foregroundStyle(.secondary)
                        Button(casting.connecting ? "取消投屏" : "返回本机播放") { controller.returnToLocal() }
                    }
                    Text("投屏期间请保持 Mac 在线。MP4、HLS 的兼容性较好，具体格式由电视决定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).frame(width: 370)
        }
        .onChange(of: presented) { showing in
            onPresentationChange(showing)
            if showing && !appleTV { casting.search() } else if !showing { casting.stopSearch() }
        }
        .onChange(of: appleTV) { apple in
            if apple {
                casting.stopSearch()
            } else { casting.search() }
        }
        .onDisappear { casting.stopSearch(); onPresentationChange(false) }
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
                Text(casting.error ?? casting.status).font(.callout).multilineTextAlignment(.center)
                Button(casting.connecting ? "取消投屏" : "返回本机播放") { controller.returnToLocal() }
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
                Text(elapsed >= 8 ? "片源响应较慢，仍在尝试连接 · \(elapsed) 秒" : "首次加载可能需要几秒钟")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                Button("取消播放", action: onCancel).font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }.padding(22).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
