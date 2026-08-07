import AVFoundation
import Foundation
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the picture fills the screen or fits inside it.
    ///
    /// It used to be neither — the layer was created `.resizeAspect` and nothing could ever
    /// change it. A clip shot in portrait on the phone is 9:16 inside a 9:19.5 screen, so it
    /// played inside a letterbox with a black band above and below it and no way to close them,
    /// while a *still* on the very same page could be double-tapped to fill. One gesture, two
    /// media types, two different answers, which reads as the gesture not working rather than as
    /// a decision.
    @State private var fills = false

    var body: some View {
        PlayerSurface(player: player,
                      gravity: fills ? .resizeAspectFill : .resizeAspect,
                      animated: !reduceMotion)
            .ignoresSafeArea()
            .contentShape(.rect)
            // The two taps are declared side by side rather than one inside the other. Nothing
            // arbitrates between a gesture on a container and a gesture within it, so a double
            // tap declared a level away would toggle the chrome on its way into the zoom —
            // the same lesson the pager learned in `PhotoViewerView`.
            .onTapGesture(count: 2) { toggleFill() }
            .onTapGesture { onSurfaceTap() }
            // The pager recycles its pages, so the next clip must not inherit the framing the
            // last one was left in. Compared by identity because that is the only thing about a
            // player that says "this is a different video".
            .onChange(of: ObjectIdentifier(player)) { _, _ in fills = false }
            // Without this the picture is not an accessibility element at all: the whole page is
            // a silent black rectangle, and every one of its gestures is a tap or a double tap,
            // which VoiceOver owns. Naming the actions is what gives them back.
            .accessibilityElement()
            .accessibilityLabel("Video")
            .accessibilityValue(fills ? "Filling the screen" : "Fitted to the screen")
            .accessibilityAction(named: fills ? "Fit to the screen" : "Fill the screen") {
                toggleFill()
            }
            .accessibilityAction(named: "Show controls") { onSurfaceTap() }
    }

    private func toggleFill() {
        fills.toggle()
        Haptics.impact(.light)
        // The picture changing shape is the only feedback this gesture has, and it is feedback
        // a reader using VoiceOver cannot see.
        AccessibilityNotification
            .Announcement(fills ? "Filling the screen" : "Fitted to the screen")
            .post()
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
    ///
    /// A floor now rather than a fixed height: the two clocks are text, and text grows.
    private static let height: CGFloat = 52

    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0

    /// Whether the clip was running when the finger landed, so it can be put back afterwards.
    ///
    /// Nothing used to stop playback for a scrub, so the picture walked away from every seek
    /// between one drag event and the next: the frame under the finger was never the frame the
    /// knob claimed, and holding a position was impossible because the position kept moving.
    /// Every first-party scrubber pauses on touch-down and resumes on touch-up.
    @State private var resumeAfterScrub = false

    /// Whether the player is waiting on its buffer rather than playing.
    ///
    /// The third state `timeControlStatus` reports, and the one that used to be thrown away.
    /// A large clip still coming down from iCloud freezes the picture, stops the clock and
    /// leaves a pause glyph over it — which is exactly what a broken app looks like.
    @State private var isStalled = false

    /// The seek that has been asked for but not started, and whether one is running.
    ///
    /// A drag produces new targets faster than a player can serve them, so they are not queued:
    /// the newest one replaces whatever was waiting, and the next seek begins only when the
    /// last has finished. Without that a fast scrub leaves a queue of stale seeks to work
    /// through after the finger has already lifted.
    @State private var pendingSeek: Double?
    @State private var seeking = false

    /// Everything this view is watching, kept together with the player it is watching.
    ///
    /// They have to travel as a pair. `AVPlayer` does not return an error when asked to remove
    /// an observer some *other* player added — it raises, and an unhandled raise from UIKit's
    /// layout pass is an immediate abort. That was the crash in the report: `stop()`,
    /// `removeTimeObserver:`, `SIGABRT`. Storing the player alongside its token means removal
    /// always goes back to whoever issued it, and clearing the pair means it can never be
    /// removed twice. The key-value observations ride along because they have the same
    /// lifetime and the same one release path.
    @State private var observation: TimeObservation?

    private struct TimeObservation {
        let player: AVPlayer
        let token: Any
        let properties: [NSKeyValueObservation]
    }

    private let knobSide: CGFloat = 14

    /// A scrubber is x-to-value arithmetic, and x runs the other way in Arabic and Hebrew.
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var mirrored: Bool { layoutDirection == .rightToLeft }

    var body: some View {
        HStack(spacing: Space.m) {
            playButton
            clocks
        }
        .padding(.horizontal, Space.gutter)
        .onAppear { start() }
        .onDisappear {
            releaseObservation()
            // The controls can be put away with a finger still on the track. This view never
            // pauses anything on its way out, and a pause it took for a drag is still a pause
            // it took.
            if resumeAfterScrub {
                resumeAfterScrub = false
                player.play()
            }
        }
    }

    // MARK: Pieces

    private var playButton: some View {
        Button { togglePlayback() } label: {
            ZStack {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    // `glyph`, not `scaled`: the circle around it cannot grow, because it is
                    // sized to match the capsule beside it and that pairing is what makes the
                    // two read as one control. What a reader who needs larger text gets instead
                    // is the label below.
                    .font(Typo.glyph(17, .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    // The glyph leaves rather than sitting behind the spinner: two white marks
                    // inside one fifty-two-point circle read as a rendering fault.
                    .opacity(isStalled ? 0 : 1)

                if isStalled {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .frame(width: Self.height, height: Self.height)
            // `frame` gives a view its size, never its touch area.
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassControl(.circle, tone: .clear)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        // Said as a value rather than folded into the label, so the button keeps naming what
        // pressing it will do while still reporting that nothing is moving yet.
        .accessibilityValue(isStalled ? "Waiting for the video" : "")
    }

    /// The two clocks and the scrubber between them.
    ///
    /// This row could not hold them at large text sizes. `1:04:22` is what `shortDuration`
    /// returns for anything over an hour, and two of those are wider than the capsule; the
    /// labels are the inflexible pair and the scrubber is the flexible one, so the labels won
    /// the layout outright and the track was squeezed to nothing. `travel` then clamped to a
    /// single point and every touch anywhere on it mapped to the end of the video.
    ///
    /// Three things hold it open now. The capsule states a floor rather than a fixed height, so
    /// nothing overflows it vertically. The clocks are allowed to shrink — they are four to
    /// seven monospaced digits, which stay perfectly readable scaled down, and they are the only
    /// thing here that can give. And the track keeps a minimum of its own so it can never be
    /// argued down to nothing again.
    ///
    /// The ceiling is the part worth explaining, because content is never capped in this app.
    /// This is not content: the viewer sizes the band these controls live in and holds it at
    /// that height whether the transport or the filmstrip is in it, precisely so the heart and
    /// the ••• menu below do not walk up the screen between one page and the next. A transport
    /// that grew past its band would be drawn over the buttons underneath it, so it is capped
    /// the same way the tab bar is, and everything the glyphs stand for is carried by the
    /// labels and by the scrubber's spoken value instead.
    private var clocks: some View {
        HStack(spacing: Space.m) {
            elapsedLabel
            scrubber
            remainingLabel
        }
        .chromeTypeSize()
        .padding(.horizontal, Space.l)
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .background(surfaceFill, in: .capsule)
    }

    private var elapsedLabel: some View {
        Text(displayed.shortDuration)
            .font(Typo.scaled(12, .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white)
            // Both clocks are folded into the scrubber's spoken value. Left as elements of
            // their own they were two unlabelled stops reading two similar bare numbers, with
            // nothing to say which was the position and which the time left.
            .accessibilityHidden(true)
    }

    private var remainingLabel: some View {
        // A real minus sign (U+2212), not a hyphen, and not an opacity difference standing in
        // for one. The two clocks are the same glyphs at the same size in the same monospaced
        // digits; every player since QuickTime has written the right-hand one as `-0:39`
        // because that is the only thing that says it counts down.
        Text(verbatim: "\u{2212}" + remaining.shortDuration)
            .font(Typo.scaled(12, .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityHidden(true)
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
                    .scaleEffect(reduceMotion ? 1 : (scrubbing ? 1.3 : 1))
                    // `.leading` mirrors and `.offset(x:)` does not — it is a raw geometric
                    // transform SwiftUI never flips. So in Arabic the fill grew correctly from
                    // the right edge while the knob was pushed the *other* way, off the end of
                    // its own track. The direction is stated here rather than hoped for.
                    .offset(x: mirrored ? -travel * fraction : travel * fraction)
            }
            // The track stays thin; the region that answers a finger does not. A four-point
            // line is something to aim at, and scrubbing was the worst of it — the touch area
            // was the drawing, so a thumb that landed a few points high did nothing at all.
            .frame(height: Hit.min)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if !scrubbing { beginScrub() }
                        // Measured from the leading edge, whichever edge that is. Without this
                        // a finger placed where the played portion visually is computed a
                        // position near zero and the video jumped to the wrong place.
                        let raw = mirrored ? proxy.size.width - value.location.x : value.location.x
                        let x = min(max(raw - knobSide / 2, 0), travel)
                        scrubTarget = Double(x / travel) * duration
                        preview(scrubTarget)
                    }
                    .onEnded { _ in endScrub() }
            )
            .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: scrubbing)
        }
        .frame(height: Hit.min)
        // A floor under the one flexible thing in the row. The clocks are text and can shrink
        // to fit; the track cannot be argued with once it has reached zero.
        .frame(minWidth: 72)
        // One element, not three shapes and a `GeometryReader`. Without it the label below has
        // nothing to land on.
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(spokenPosition)
        // The position was carried entirely by a `DragGesture`, and VoiceOver never delivers
        // single-finger drags to one. A clip could be played and paused but never moved: the
        // playhead was reachable by finger only. This is what confers the adjustable trait, so
        // a swipe up or down on the scrubber now seeks.
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            // A twentieth of the clip per swipe, and never less than a second — proportional so
            // an hour-long film is not crossed one second at a time, floored so a six-second
            // clip still moves.
            let step = max(1, duration / 20)
            switch direction {
            case .increment: seek(to: min(duration, position + step))
            case .decrement: seek(to: max(0, position - step))
            @unknown default: break
            }
        }
    }

    private var displayed: Double { scrubbing ? scrubTarget : position }
    private var remaining: Double { max(0, duration - displayed) }

    /// Where the playhead is, said rather than shown.
    ///
    /// `0:07` on its own is not an answer to anything — it could be the position, the time left
    /// or the length of the clip. Both numbers, in words, in one sentence.
    private var spokenPosition: String {
        guard duration > 0 else { return displayed.spokenDuration }
        return "\(displayed.spokenDuration) of \(duration.spokenDuration)"
    }

    /// The capsule behind the clocks, and what it becomes when the reader has asked iOS to stop
    /// making things see-through.
    ///
    /// Opaque black rather than a system fill: this floats over a photograph in a black
    /// full-screen viewer and everything drawn on it is white. Handing it `systemBackground`
    /// would put a white slab under white type in light mode. It is the same reasoning as
    /// `GlassTone.clear`'s own fallback.
    private var surfaceFill: Color {
        reduceTransparency ? .black : ViewerSurface.fill
    }

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

        var properties: [NSKeyValueObservation] = []

        // The duration used to be discovered *only* inside the periodic observer, and a periodic
        // observer does not fire periodically while the player is paused. A freshly vended item
        // reports an indefinite duration until it is ready, so with autoplay turned off the
        // transport opened at `0:00`, pinned the knob to the far end of the track and threw away
        // every drag — a scrubber that visibly did nothing until the user happened to press
        // play. This asks the item instead of sampling it.
        if let item = player.currentItem {
            properties.append(item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    if duration == 0 { duration = finiteDuration }
                }
            })
        }

        properties.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            // Key-value observing makes no promise about which queue this arrives on, and
            // everything it touches is view state.
            DispatchQueue.main.async {
                // A scrub pauses the player on purpose; the button must not flicker to a play
                // glyph and back for the length of a drag because of it.
                guard !scrubbing else { return }
                isPlaying = player.timeControlStatus != .paused

                let reason = player.reasonForWaitingToPlay
                let buffering = reason == AVPlayer.WaitingReason.toMinimizeStalls
                    || reason == AVPlayer.WaitingReason.evaluatingBufferingRate
                isStalled = player.timeControlStatus == .waitingToPlayAtSpecifiedRate && buffering
            }
        })

        observation = TimeObservation(player: player, token: token, properties: properties)
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
        for property in observation.properties { property.invalidate() }
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

    /// Takes the playhead off the player and gives it to the finger.
    private func beginScrub() {
        scrubbing = true
        resumeAfterScrub = player.timeControlStatus != .paused
        player.pause()
        Haptics.selection()
    }

    /// Lands the exact seek, and only then hands playback back.
    ///
    /// `scrubbing` stays true until the seek has finished, so the knob holds where the finger
    /// left it instead of snapping back to the last position the player reported and then
    /// jumping forwards again when the seek arrives.
    private func endScrub() {
        // A drag that never started — the clip's length is not known yet, so every `onChanged`
        // turned back at the door. Seeking to a target nobody set would throw the video to its
        // beginning on a stray touch.
        guard scrubbing else { return }

        let target = scrubTarget
        // Nothing loose is left waiting behind an exact seek; it would only undo it.
        pendingSeek = nil
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                scrubbing = false
                if resumeAfterScrub {
                    resumeAfterScrub = false
                    player.play()
                }
            }
        }
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

// `spokenDuration` — "41 seconds" rather than the clock face "0:41", which a voice reads as a
// time of day or as two unrelated numbers — lives beside `shortDuration` in
// `DesignSystem/PhotoImageView.swift`. Both of them are `Double`, both are read by the grid
// badge, the filmstrip and this transport, and two copies of the same extension on the same
// type is not an abstraction, it is a redeclaration.

/// An `AVPlayerLayer` with nothing attached to it — no controls, no gestures, no chrome.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// Whether the change of framing is allowed to be a movement. Reduce Motion turns a resize
    /// of the whole screen into a cut.
    var animated: Bool = true

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }

        guard view.playerLayer.videoGravity != gravity else { return }
        // A layer property changes with an implicit animation whether or not anyone asked for
        // one, and SwiftUI's animation machinery never sees it. The transaction is the only
        // route the reader's Reduce Motion setting has into Core Animation.
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        view.playerLayer.videoGravity = gravity
        CATransaction.commit()
    }

    /// Lets go of the player the moment the page is taken away.
    ///
    /// Without this the layer holds its player until the backing `UIView` is deallocated, which
    /// in a pager that recycles pages can be several swipes later — so a memory made mostly of
    /// clips keeps a decoder and a render pipeline alive per page visited, and shows it as
    /// memory growth and dropped frames rather than as anything obviously wrong.
    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
