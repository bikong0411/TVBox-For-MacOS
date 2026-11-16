import SwiftUI

struct PlaybackRateMenu: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var casting: DLNACastingController
    var body: some View {
        Menu {
            ForEach([Float(0.5), 1, 1.25, 1.5, 2], id: \.self) { rate in
                Button("\(String(format: "%g", rate))×") { controller.setRate(rate) }
            }
        } label: { Text("\(String(format: "%g", casting.connected ? 1 : controller.rate))×") }
            .frame(width: 70).disabled(casting.selectedDevice != nil)
    }
}
