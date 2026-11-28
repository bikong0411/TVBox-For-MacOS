import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import TVBoxCore

struct PlaybackAuthorizationPrompt: View {
    let authorization: CSPPlaybackAuthorization
    let sourceName: String
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let image = Self.qrImage(for: authorization)
        VStack(spacing: 12) {
            Label(L10n.text("扫码授权"), systemImage: "qrcode")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(sourceName).foregroundStyle(Theme.muted).lineLimit(1)
            if let image {
                Image(image, scale: 1, label: Text(L10n.text("片源授权二维码")))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 176, height: 176)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.text("请用片源对应的手机 App 扫码，并在手机上核对授权内容。"))
            } else {
                Text(L10n.text("二维码无法显示，请重试获取。"))
            }
            HStack(spacing: 12) {
                Button(L10n.text("取消"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(image == nil ? L10n.text("重试获取二维码") : L10n.text("已扫码，继续播放"), action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .tint(Theme.accent)
        .environment(\.colorScheme, .dark)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .padding(12)
    }

    static func qrImage(for authorization: CSPPlaybackAuthorization) -> CGImage? {
        switch authorization {
        case .code(let content):
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(content.utf8)
            filter.correctionLevel = "M"
            guard let image = filter.outputImage else { return nil }
            return imageContext.createCGImage(image, from: image.extent)
        case .image(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let type = CGImageSourceGetType(source) as String?,
                  ["public.png", "public.jpeg"].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (21...1024).contains(width), (21...1024).contains(height) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    private static let imageContext = CIContext()
}
