import Photos
import SwiftUI

/// Draws one asset. Every photograph in the app goes through here.
///
/// Loading is asynchronous and the placeholder is a calm tone rather than a spinner: at feed
/// scale a screen full of spinners looks broken even when nothing is wrong. Assets that live
/// only in iCloud say so instead of hanging, because indexing never downloads them.
struct PhotoImageView: View {
    let identifier: String
    var targetSide: CGFloat = 400
    var purpose: ImagePurpose = .browsing
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var isUnavailable = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.surfaceSunk

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if isUnavailable {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.22))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.easeOut(duration: 0.22), value: image != nil)
            .task(id: identifier) { await load(side: max(proxy.size.width, proxy.size.height)) }
        }
    }

    private func load(side: CGFloat) async {
        image = nil
        isUnavailable = false
        let requested = max(side, targetSide) * UIScreen.main.scale
        let loaded = await PhotoImageLoader.shared.image(
            forIdentifier: identifier,
            targetSize: CGSize(width: requested, height: requested),
            purpose: purpose
        )
        if let loaded {
            image = loaded
        } else {
            isUnavailable = true
        }
    }
}

/// A square thumbnail with the app's standard corner treatment.
struct PhotoThumbnail: View {
    let identifier: String
    var side: CGFloat = 84
    var radius: CGFloat = Radius.thumb

    var body: some View {
        PhotoImageView(identifier: identifier, targetSide: side)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            }
    }
}

/// Marks videos and Live Photos without covering the image.
struct MediaBadge: View {
    let record: AssetRecord

    var body: some View {
        Group {
            if record.isVideo {
                Label(record.duration.shortDuration, systemImage: "play.fill")
            } else if record.isLivePhoto {
                Label("LIVE", systemImage: "livephoto")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.45), in: .capsule)
    }
}

extension TimeInterval {
    /// `2:07`, or `1:04:22` for anything over an hour.
    var shortDuration: String {
        let total = Int(rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
