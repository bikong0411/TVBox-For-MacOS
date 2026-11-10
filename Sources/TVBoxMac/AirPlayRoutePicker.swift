import SwiftUI
import AVKit

/// The system picker routes the same AVPlayer used by inline and fullscreen
/// playback. It owns discovery, pairing, device selection and disconnection.
struct AirPlayRoutePicker: NSViewRepresentable {
    let player: AVPlayer
    var onPresentationChange: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(onPresentationChange: onPresentationChange) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.player = player; view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(NSColor(Theme.accent), for: .active)
        view.setRoutePickerButtonColor(NSColor(Theme.accent), for: .activeHighlighted)
        view.setAccessibilityLabel("AirPlay 投屏")
        view.toolTip = "AirPlay 投屏：选择同一网络中的兼容电视；选择此 Mac 可停止投屏。"
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        context.coordinator.onPresentationChange = onPresentationChange
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVRoutePickerView, coordinator: Coordinator) {
        view.delegate = nil; view.player = nil
    }
    @MainActor final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentationChange: (Bool) -> Void
        init(onPresentationChange: @escaping (Bool) -> Void) { self.onPresentationChange = onPresentationChange }
        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor [weak self] in self?.onPresentationChange(true) }
        }
        nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor [weak self] in self?.onPresentationChange(false) }
        }
    }
}

struct AirPlayPlaybackStatus: View {
    @ObservedObject var surface: PersistentVideoSurface
    var body: some View {
        if surface.externalPlaybackActive {
            Label("正在通过 AirPlay 播放", systemImage: "airplayvideo")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                .padding(18).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
        }
    }
}
