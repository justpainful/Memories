import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

struct MemoryRenderableSurface: View {
    let candidate: MemoryCandidate
    let presentation: MemoryPlaybackPresentation?
    let isActive: Bool
    let isMuted: Bool

    var body: some View {
        Group {
            switch presentation {
            case .photo(let image):
                InspectableMemoryPhotoView(image: image)

            case .video(let url):
                AutoPlayingMemoryVideoView(url: url, isMuted: isMuted, shouldPlay: isActive)

            case .livePhoto(let livePhoto):
                AutoPlayingMemoryLivePhotoView(livePhoto: livePhoto, isMuted: isMuted, shouldPlay: isActive)

            case .none:
                MemoryMediaPlaceholder(candidate: candidate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }
}

private struct MemoryMediaPlaceholder: View {
    let candidate: MemoryCandidate

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.18, blue: 0.24),
                    Color(red: 0.03, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Image(systemName: candidate.mediaKind.symbolName)
                    .font(.system(size: 42, weight: .medium))
                Text("Preparing memory")
                    .font(.headline)
            }
            .foregroundStyle(.white.opacity(0.86))
        }
    }
}

struct InspectableMemoryPhotoView: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let doubleTapGesture = TapGesture(count: 2)
                .onEnded {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        if scale > 1.01 {
                            resetInspectState()
                        } else {
                            scale = 2.1
                        }
                    }
                }

            let dragGesture = DragGesture()
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = clampedOffset(
                        proposed: CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        ),
                        in: geometry.size
                    )
                }
                .onEnded { _ in
                    lastOffset = offset
                }

            let magnifyGesture = MagnifyGesture()
                .onChanged { value in
                    let nextScale = max(1, min(4, lastScale * value.magnification))
                    scale = nextScale
                    offset = clampedOffset(proposed: offset, in: geometry.size)
                }
                .onEnded { _ in
                    lastScale = scale
                    if scale <= 1.01 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            resetInspectState()
                        }
                    }
                }

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .gesture(dragGesture.simultaneously(with: magnifyGesture))
                .simultaneousGesture(doubleTapGesture)
                .animation(.snappy(duration: 0.2), value: scale)
                .animation(.snappy(duration: 0.2), value: offset)
                .accessibilityLabel("Photo memory")
        }
    }

    private func resetInspectState() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    private func clampedOffset(proposed: CGSize, in size: CGSize) -> CGSize {
        let maxX = max(0, (size.width * (scale - 1)) / 2)
        let maxY = max(0, (size.height * (scale - 1)) / 2)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

struct AutoPlayingMemoryVideoView: View {
    let url: URL
    let isMuted: Bool
    let shouldPlay: Bool

    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) {
                let item = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: item)
                player.actionAtItemEnd = .none
                player.isMuted = isMuted

                if shouldPlay {
                    player.play()
                }
            }
            .onChange(of: isMuted) { _, newValue in
                player.isMuted = newValue
            }
            .onChange(of: shouldPlay) { _, newValue in
                if newValue {
                    player.play()
                } else {
                    player.pause()
                }
            }
            .onDisappear {
                player.pause()
            }
            .ignoresSafeArea()
            .accessibilityLabel("Video memory")
    }
}

struct AutoPlayingMemoryLivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isMuted: Bool
    let shouldPlay: Bool

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        uiView.livePhoto = livePhoto
        uiView.isMuted = isMuted

        if shouldPlay {
            uiView.startPlayback(with: .full)
        } else {
            uiView.stopPlayback()
        }
    }
}

struct MemoryShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
