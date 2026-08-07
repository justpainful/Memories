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
    /// Tapping the picture belongs to the viewer, not to this player. If it toggled playback
    /// instead, then once the controls auto-hid there would be no way to bring back Back,
    /// Love or the ••• menu, and a full-screen cover has no interactive dismiss to escape by.
    var onSurfaceTap: () -> Void

    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0
    @State private var isMuted = false

    /// The periodic time observer, kept together with the player that installed it.
    ///
    /// They have to travel as a pair. `AVPlayer` does not return an error when asked to remove
    /// an observer some *other* player added — it raises, and an unhandled raise from UIKit's
    /// layout pass is an immediate abort. That is the crash in the report: `stop()`,
    /// `removeTimeObserver:`, `SIGABRT`.
    ///
    /// It happened because the viewer's pager recycles this view. When a page scrolls away and
    /// comes back holding a different video, `player` is a new object while SwiftUI keeps the
    /// `@State` from the previous one, so the old token was handed to the new player. Storing
    /// the player alongside its token means removal always goes back to whoever issued it, and
    /// clearing the pair means it can never be removed twice.
    @State private var observation: TimeObservation?

    private struct TimeObservation {
        let player: AVPlayer
        let token: Any
    }

    var body: some View {
        ZStack {
            PlayerSurface(player: player)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { onSurfaceTap() }

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
            // 44 across, which is the smallest target Apple will vouch for and the reason
            // these were hard to hit: the icon was drawn at 28 and the touch area was the icon.
            // The glyph is unchanged; only the region that answers a finger grew.
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
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
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, 4)
        .glassPanel(cornerRadius: 28, tone: .clear)
        // No drop shadow. Glass over a moving picture already separates itself by refracting
        // it; a shadow underneath as well is what turned this strip into a grey slab pasted
        // over the video instead of a piece of the app floating on it.
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
            // The track stays thin; the region that answers a finger does not. A 3-point line
            // is something to aim at, and scrubbing was the worst of it — the touch area was
            // the drawing, so a thumb that landed a few points high did nothing at all.
            .frame(height: 44)
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
        .frame(height: 44)
        .accessibilityLabel("Playback position")
    }

    private var displayed: Double { scrubbing ? scrubTarget : position }

    // MARK: Playback

    private func start() {
        // The pager can bring the next video on screen before the last one has finished
        // leaving, so whatever is still running is torn down before anything new is installed.
        releaseObservation()

        isMuted = player.isMuted
        duration = player.currentItem?.duration.seconds ?? 0
        if duration.isNaN || duration.isInfinite { duration = 0 }

        // A tenth of a second is enough to keep the scrubber honest without waking the
        // main thread more than it deserves.
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            position = time.seconds
            if duration == 0, let itemDuration = player.currentItem?.duration.seconds,
               itemDuration.isFinite {
                duration = itemDuration
            }
        }
        observation = TimeObservation(player: player, token: token)

        if autoplay {
            player.play()
            isPlaying = true
        }
    }

    private func stop() {
        releaseObservation()
        player.pause()
        isPlaying = false
    }

    /// Hands the token back to the player that issued it, and only ever once.
    private func releaseObservation() {
        guard let observation else { return }
        observation.player.removeTimeObserver(observation.token)
        self.observation = nil
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
