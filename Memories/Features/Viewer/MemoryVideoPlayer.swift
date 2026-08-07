import AVFoundation
import SwiftUI

/// The video surface for the viewer, and nothing else.
///
/// Deliberately not `VideoPlayer`: that brings AVKit's own control bar, its own chrome and its
/// own idea of what a full-screen video should look like, none of which match this app.
///
/// It also draws no controls of its own any more. Those are `VideoTransport`, and the viewer
/// puts them in its own column beside Back and the heart. The two used to be separate floating
/// stacks — the transport inside the page, positioned by guessing how tall the viewer's chrome
/// was, and the chrome outside it — and the guess was about thirty points short, so the
/// filmstrip sat on top of the scrubber and answered every touch aimed at it. Two panes of
/// clear glass overlapping look like one pane, which is why that never showed in a screenshot
/// and only ever showed under a thumb.
struct MemoryVideoPlayer: View {
    let player: AVPlayer
    /// Tapping the picture belongs to the viewer, not to this player. If it toggled playback
    /// instead, then once the controls were put away there would be no way to bring back Back,
    /// Love or the ••• menu, and a full-screen cover has no interactive dismiss to escape by.
    var onSurfaceTap: () -> Void

    var body: some View {
        PlayerSurface(player: player)
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture { onSurfaceTap() }
    }
}

// MARK: - Transport

/// Play, position and elapsed time for the video the viewer is showing.
///
/// Two pieces rather than one bar the width of the screen: a round button and a capsule. A
/// single wide slab of translucency over a moving picture is the thing that reads as a smear,
/// and it was carrying five controls — play, two clocks, a scrubber and a mute — where three
/// belong. Sound moved up to the top bar, next to Back, where it also fills a corner that used
/// to hold an invisible square.
///
/// The capsule is a flat surface, not glass; the round button keeps the app's glass. The
/// reason is in `ViewerSurface`.
///
/// This view exists only while the controls are showing, so it owns nothing that playback
/// depends on. It reads the player's real state when it appears rather than trusting what it
/// was told last, and it never pauses anything on the way out.
struct VideoTransport: View {
    let player: AVPlayer
    @Binding var isPlaying: Bool

    /// The play button and the capsule beside it are the same size, which is what makes the two
    /// read as one control rather than as a button that happens to sit near a bar. It is also
    /// eight points past the smallest target Apple will vouch for.
    private static let height: CGFloat = 52

    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0

    /// The seek that has been asked for but not started, and whether one is running.
    ///
    /// A drag produces new targets faster than a player can serve them, so they are not queued:
    /// the newest one replaces whatever was waiting, and the next seek begins only when the
    /// last has finished. Without that a fast scrub leaves a queue of stale seeks to work
    /// through after the finger has already lifted.
    @State private var pendingSeek: Double?
    @State private var seeking = false

    /// The periodic time observer, kept together with the player that installed it.
    ///
    /// They have to travel as a pair. `AVPlayer` does not return an error when asked to remove
    /// an observer some *other* player added — it raises, and an unhandled raise from UIKit's
    /// layout pass is an immediate abort. That was the crash in the report: `stop()`,
    /// `removeTimeObserver:`, `SIGABRT`. Storing the player alongside its token means removal
    /// always goes back to whoever issued it, and clearing the pair means it can never be
    /// removed twice.
    @State private var observation: TimeObservation?

    private struct TimeObservation {
        let player: AVPlayer
        let token: Any
    }

    private let knobSide: CGFloat = 14

    var body: some View {
        HStack(spacing: Space.m) {
            Button { togglePlayback() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassControl(.circle, tone: .clear)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            HStack(spacing: Space.m) {
                Text(displayed.shortDuration)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                scrubber
                Text(remaining.shortDuration)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, Space.l)
            .frame(height: Self.height)
            .background(ViewerSurface.fill, in: .capsule)
        }
        .padding(.horizontal, Space.gutter)
        .onAppear { start() }
        .onDisappear { releaseObservation() }
    }

    /// A plain track and knob rather than a `Slider`, so it can stay thin enough not to compete
    /// with the picture while still answering a whole thumb.
    private var scrubber: some View {
        GeometryReader { proxy in
            // The knob is inset by its own width so that neither end of it hangs off the track,
            // and the finger is mapped through the same inset — otherwise the last few points
            // of a drag move the knob nowhere and the end of a video is unreachable.
            let travel = max(1, proxy.size.width - knobSide)
            let fraction = CGFloat(duration > 0 ? min(1, max(0, displayed / duration)) : 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: knobSide / 2 + travel * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: knobSide, height: knobSide)
                    .scaleEffect(scrubbing ? 1.3 : 1)
                    .offset(x: travel * fraction)
            }
            // The track stays thin; the region that answers a finger does not. A four-point
            // line is something to aim at, and scrubbing was the worst of it — the touch area
            // was the drawing, so a thumb that landed a few points high did nothing at all.
            .frame(height: 44)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if !scrubbing {
                            scrubbing = true
                            Haptics.selection()
                        }
                        let x = min(max(value.location.x - knobSide / 2, 0), travel)
                        scrubTarget = Double(x / travel) * duration
                        preview(scrubTarget)
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
        .accessibilityValue(displayed.shortDuration)
    }

    private var displayed: Double { scrubbing ? scrubTarget : position }
    private var remaining: Double { max(0, duration - displayed) }

    // MARK: Playback

    private func start() {
        // Whatever this view was watching last is released before anything new is installed;
        // the pager can bring the next clip on screen before the last has finished leaving.
        releaseObservation()

        duration = finiteDuration
        let now = player.currentTime().seconds
        position = now.isFinite ? now : 0

        // Read the player rather than trust the last thing it was told. The controls are put
        // away and brought back constantly, and playback carries on without this view — so a
        // clip that ran to its end while the chrome was hidden must not come back showing a
        // pause icon over a video that has stopped.
        //
        // Not `== .playing`: a clip that has only just been told to play spends its first
        // moments waiting on its buffer, and reading that as stopped would put a play icon over
        // a video that is in the act of starting.
        isPlaying = player.timeControlStatus != .paused

        // A tenth of a second is enough to keep the scrubber honest without waking the
        // main thread more than it deserves.
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            // While the finger is down the knob belongs to the finger.
            guard !scrubbing else { return }
            position = time.seconds
            if duration == 0 { duration = finiteDuration }
        }
        observation = TimeObservation(player: player, token: token)
    }

    /// Zero rather than a nonsense number. An item that has not finished loading reports an
    /// indefinite duration, and dividing by it puts the knob at `NaN`, which lands it off the
    /// left edge of the track for as long as the video takes to open.
    private var finiteDuration: Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? max(0, seconds) : 0
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

    /// Moves the picture while the finger is still down.
    ///
    /// A scrubber you can only aim by letting go is not a scrubber — you cannot see where you
    /// are going until you have already arrived. The seek is loose on purpose: frame-exact
    /// seeking costs a decode and is not worth paying for until the finger lifts.
    private func preview(_ seconds: Double) {
        pendingSeek = seconds
        guard !seeking else { return }
        chaseSeek()
    }

    private func chaseSeek() {
        guard let target = pendingSeek else {
            seeking = false
            return
        }
        pendingSeek = nil
        seeking = true

        let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance) { _ in
            // AVFoundation makes no promise about which queue this arrives on, and everything
            // it touches is view state.
            DispatchQueue.main.async { chaseSeek() }
        }
    }

    private func seek(to seconds: Double) {
        // Nothing loose is left waiting behind an exact seek; it would only undo it.
        pendingSeek = nil
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
