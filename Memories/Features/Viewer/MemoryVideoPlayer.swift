import AVFoundation
import SwiftUI

/// The video surface for the viewer.
///
/// Deliberately not `VideoPlayer`: that brings AVKit's own control bar, its own chrome and
/// its own idea of what a full-screen video should look like, none of which match this app.
/// Here the frame is the whole screen and the only thing over it is one clear glass strip
/// that fades away with the rest of the viewer's controls.
struct MemoryVideoPlayer: View {
    let player: AVPlayer
    let showControls: Bool
    var autoplay: Bool

    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var isMuted = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack {
            PlayerSurface(player: player)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { togglePlayback() }

            if showControls {
                VStack {
                    Spacer()
                    controls
                        .padding(.horizontal, Space.gutter)
                        .padding(.bottom, 96)   // clears the viewer's own button cluster
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: showControls)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: Space.m) {
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Text(displayed.shortDuration)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))

            scrubber

            Text(max(0, duration - displayed).shortDuration)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))

            Button { toggleMute() } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 26, tone: .clear)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    /// A plain track and knob rather than a `Slider`, so it matches the rest of the viewer
    /// and can stay thin enough not to compete with the picture.
    private var scrubber: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(1, max(0, displayed / duration)) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: 3)
                Capsule().fill(.white).frame(width: width * fraction, height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: scrubbing ? 14 : 10, height: scrubbing ? 14 : 10)
                    .offset(x: width * fraction - (scrubbing ? 7 : 5))
                    .shadow(color: .black.opacity(0.25), radius: 2)
            }
            .frame(height: 20)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubbing = true
                        scrubTarget = min(duration, max(0, Double(value.location.x / width) * duration))
                    }
                    .onEnded { _ in
                        seek(to: scrubTarget)
                        scrubbing = false
                    }
            )
            .animation(.smooth(duration: 0.15), value: scrubbing)
        }
        .frame(height: 20)
        .accessibilityLabel("Playback position")
    }

    private var displayed: Double { scrubbing ? scrubTarget : position }

    // MARK: Playback

    private func start() {
        isMuted = player.isMuted
        duration = player.currentItem?.duration.seconds ?? 0
        if duration.isNaN || duration.isInfinite { duration = 0 }

        // A tenth of a second is enough to keep the scrubber honest without waking the
        // main thread more than it deserves.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            position = time.seconds
            if duration == 0, let itemDuration = player.currentItem?.duration.seconds,
               itemDuration.isFinite {
                duration = itemDuration
            }
        }

        if autoplay {
            player.play()
            isPlaying = true
        }
    }

    private func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        isPlaying = false
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            // Replay from the start once it has run to the end, rather than doing nothing.
            if duration > 0, position >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
        isPlaying.toggle()
        Haptics.impact(.light)
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        position = seconds
    }
}

/// An `AVPlayerLayer` with nothing attached to it — no controls, no gestures, no chrome.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
