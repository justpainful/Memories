import AVFoundation
import AVKit
import Combine
import PhotosUI
import SwiftData
import SwiftUI

/// Full screen. The photograph is the whole screen and the only thing on it.
///
/// Controls are one floating glass cluster that a tap puts away and a tap brings back. They do
/// not leave on their own after a couple of seconds any more: chrome that disappears while a
/// thumb is already travelling towards it turns a deliberate tap on the heart into a tap on
/// the photograph, and from the outside that is indistinguishable from the app missing the
/// touch. Photos has never hidden its chrome on a timer, and neither does this.
///
/// Exactly one gesture answers a finger on the picture, and the page under it owns that
/// gesture — the single tap and the double tap are declared side by side rather than two
/// levels apart. Vertical drags belong to the viewer: up for the details panel, down to leave.
///
/// What is known *about* the photograph stays out of sight until it is asked for: swipe up
/// on the picture, or ••• → Details. It arrives as a sheet with detents, so a short pull
/// shows what matters and dragging it taller shows the rest.
struct PhotoViewerView: View {
    let identifiers: [String]
    let startAt: String

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    /// Playback is the one thing in this app that has to know the app went away. The system
    /// stops the picture on the way out and says nothing to the view that drew the button, so
    /// without this the user comes back to a pause glyph over a video that is not running.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Height is the scarce dimension in landscape, and this screen's whole point is the
    /// picture. The chrome answers that rather than keeping the proportions it was drawn with
    /// on a phone held upright.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var current: String
    @State private var showControls = true
    @State private var showDetails = false
    @State private var sharing: ShareRequest?
    @State private var similarFor: String?
    @State private var eventFor: String?
    @State private var dayWindow: TimeWindow?
    @State private var isSaving = false
    @State private var confirmation: Confirmation?
    @State private var zoom = ViewerZoom()

    /// Where the clip on screen has got to, when it is not simply playing.
    ///
    /// A video that lives only in iCloud is pulled down before it can be shown, and for a 4K
    /// clip that is tens of seconds during which the old code drew nothing at all: no
    /// progress, no explanation, and — if the fetch failed — no end to it either. This is what
    /// the transport's slot shows instead of an empty band.
    @State private var videoLoad: VideoLoad = .idle

    /// Whether the mute button has been set from the stored preference yet.
    ///
    /// Once, when the viewer opens, and never again. It used to be reset on every page turn,
    /// so a user watching a memory made of five clips had to unmute five times — the previous
    /// tap thrown away the instant the page moved.
    @State private var hasSeededMute = false

    /// The row for whatever is on screen, read once per photograph instead of on every pass of
    /// this body.
    ///
    /// A pinch or a pan rewrites `zoom` many times a second and each of those runs this body
    /// again. Going back to SwiftData for the same row sixty times a second is work a gesture
    /// cannot afford, and a gesture that drops frames is indistinguishable from one that is
    /// not tracking the finger.
    @State private var record: AssetRecord?

    /// The player for the video on screen, and for nothing else.
    ///
    /// It is held here rather than inside the page for two reasons. Only the photograph the
    /// user is actually looking at ever has one, so paging through a memory full of clips can
    /// never leave a row of players alive behind it. And the transport belongs in the viewer's
    /// own column of controls, beside Back and the heart, rather than being a second floating
    /// stack inside the page trying to guess where the first one ends.
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isMuted = false

    /// What the heart is showing while the tap is still in flight, and `nil` whenever it is
    /// simply showing what is stored.
    ///
    /// Loving a photograph has to reach the Photos library, which takes a moment and can be
    /// refused, so the icon cannot wait for it — but it also must not lie about it. This is
    /// set the instant the finger lands and put back if the library says no. Keeping it apart
    /// from the stored value is also what stops the picture arriving with the previous
    /// photograph's heart still lit.
    @State private var lovedOverride: Bool?

    /// The band above the button cluster, tall enough for the filmstrip — 56 for a cell and 8
    /// of air either side of it — and held at that whether the transport or the strip is in it.
    private let slotHeight: CGFloat = 72

    init(identifiers: [String], startAt: String) {
        self.identifiers = identifiers
        self.startAt = startAt
        _current = State(initialValue: startAt)
    }

    /// A note about what just happened, and whether it was bad news.
    ///
    /// The two are not the same thing and must not disappear on the same timer: "Loved" is a
    /// receipt and can go on its own, but Photos refusing the write is the only explanation
    /// the user will ever get and they may not have been looking at it.
    private struct Confirmation: Equatable {
        let text: String
        var isFailure = false
    }

    /// What the viewer is waiting on before a clip can play.
    private enum VideoLoad: Equatable {
        case idle
        /// The original is in iCloud and is being fetched. There is no fraction to show — the
        /// loader hands back one item or nothing — so this says what is happening rather than
        /// pretending to a percentage.
        case downloading
        case failed(String)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(identifiers, id: \.self) { identifier in
                    ViewerPage(identifier: identifier,
                               isCurrent: identifier == current,
                               player: identifier == current ? player : nil,
                               zoom: identifier == current ? $zoom : .constant(ViewerZoom()),
                               onSurfaceTap: { toggleControls() },
                               // Everything the picture can be made to do by a gesture, named
                               // so it can also be done from the rotor. Swipe up for details,
                               // swipe down to leave and double tap to zoom are three actions
                               // that were reachable only by moving a finger a particular
                               // distance in a particular direction, which is to say not at
                               // all with VoiceOver on.
                               onDetails: { showDetails = true },
                               onClose: { dismiss() },
                               onToggleZoom: { toggleZoomFromAccessibility() })
                        .tag(identifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            // No tap gesture here. There used to be one, and it was the single tap that
            // toggles the controls — two levels above the double tap that zooms. Nothing
            // arbitrates between a gesture on a container and a gesture inside it, so a double
            // tap toggled the chrome on its way into the zoom and a quick single tap was
            // sometimes swallowed outright. Each page now owns its own tap.
            .simultaneousGesture(revealDetails, including: zoom.isZoomed ? .subviews : .all)

            if showControls {
                VStack {
                    topBar
                    Spacer()
                    bottomSlot
                    bottomCluster
                }
                .transition(.opacity)
            }

            if let confirmation {
                Text(confirmation.text)
                    .font(Typo.control)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .viewerSurface(in: .capsule)
                    .padding(.horizontal, Space.gutter)
                    // A size change on a floating overlay is exactly what Reduce Motion asks
                    // to be spared, and this is one of the three most frequently triggered
                    // overlays in the app.
                    .transition(reduceMotion ? .opacity
                                             : .opacity.combined(with: .scale(scale: 0.95)))
                    // A receipt must never be the thing that eats the next tap — it sits in the
                    // middle of the picture, right where the finger is. Bad news is different:
                    // it has no timer any more, so it has to be dismissible.
                    .onTapGesture { self.confirmation = nil }
                    .allowsHitTesting(confirmation.isFailure)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .statusBarHidden(!showControls)
        // The zoom transition brings a pull-to-dismiss of its own with it. That is welcome at
        // fit scale, but while the photograph is enlarged a downward drag means panning, and
        // the presentation would otherwise take the gesture away mid-pan.
        .interactiveDismissDisabled(zoom.isZoomed)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: showControls)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: confirmation)
        .onAppear {
            seedMute()
            settleOnCurrent()
        }
        .onDisappear { leaveViewer() }
        .onChange(of: current) { _, _ in settleOnCurrent() }
        // A two-minute clip and a static page look identical to Auto-Lock, so the screen dims
        // and then locks in the middle of a video unless somebody says otherwise. Every
        // first-party player says otherwise, and every one of them puts it back — an idle
        // timer left disabled drains the whole device, not just this screen.
        .onChange(of: isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Believe the player rather than what it was last told: the system may have
                // stopped it on the way out, and the button has to agree with the picture.
                if let player {
                    isPlaying = player.timeControlStatus != .paused
                } else {
                    isPlaying = false
                }
            default:
                pausePlayback()
            }
        }
        // A sheet over a playing clip leaves it running and audible underneath, talking over
        // whatever the user opened the sheet to read. Photos pauses; so does this.
        .onChange(of: isPresenting) { _, presenting in
            if presenting { pausePlayback() }
        }
        // A phone call, a timer or Siri takes the session away mid-clip. Without this the
        // picture stops and the button goes on claiming it is playing.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            pausePlayback()
        }
        // Off the main actor and cancelled when the page turns, because scrubbing the
        // filmstrip changes `current` many times a second and each of these is a hit on the
        // Photos database.
        .task(id: current) { await loadCurrent() }
        // The play button has to agree with the player. Without this a clip that runs to its
        // end leaves a pause icon on screen over a video that has stopped, and the tap that
        // restarts it from the beginning looks like a tap that did nothing.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            // The controls come back at the end of a clip. Watching a video with the chrome
            // put away, nothing on screen changed when it finished — the last frame simply
            // stayed, and the only way to find out it had ended was to tap the picture.
            showControls = true
        }
        .sheet(isPresented: $showDetails) {
            AssetDetailsView(identifier: current)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // Detents describe a compact-width sheet and are ignored on a wide window,
                // where a sheet that says nothing about itself is given a size by the system.
                // A list of facts is a form; a grid of photographs is a page.
                .presentationSizing(.form)
        }
        .sheet(item: Binding(
            get: { similarFor.map(ViewerRequest.init(identifier:)) },
            set: { similarFor = $0?.identifier }
        )) { request in
            SimilarPhotosView(identifier: request.identifier)
                .presentationSizing(.page)
        }
        .sheet(item: $sharing) { request in
            ShareSheet(items: request.items)
        }
        .sheet(item: Binding(
            get: { eventFor.map(ViewerRequest.init(identifier:)) },
            set: { eventFor = $0?.identifier }
        )) { request in
            EventSheet(identifier: request.identifier)
                .presentationSizing(.page)
        }
        .sheet(item: $dayWindow) { window in
            TimeWindowResultsView(window: window)
                .presentationSizing(.page)
        }
        .sheet(isPresented: $isSaving) {
            AddToCollectionSheet(
                items: [CollectionItem(kind: .asset, reference: current)],
                suggestedCover: current
            ) { name in
                confirm("Kept in \(name)")
            }
            .presentationDetents([.medium, .large])
            .presentationSizing(.form)
        }
    }

    /// True while anything at all is covering the viewer.
    ///
    /// Gathered into one value rather than six `onChange`s, because the rule is the same for
    /// all of them and six copies of it is six chances for the seventh sheet to be forgotten.
    private var isPresenting: Bool {
        showDetails || isSaving || sharing != nil
            || similarFor != nil || eventFor != nil || dayWindow != nil
    }

    // MARK: Revealing the details

    /// Vertical swipes on the photograph: up for the details panel, down to leave.
    ///
    /// Swipe-down-to-dismiss matters more than it looks. A full-screen cover has no interactive
    /// dismiss of its own, and Photos has always let you throw the picture away downward, so
    /// this is the gesture people reach for before they look for a button.
    ///
    /// Two other gestures already want this touch: the pager's horizontal scroll and the tap
    /// that toggles the controls. So this runs *simultaneously* rather than competing — it
    /// never claims the touch while the finger is down, and decides only once the finger
    /// lifts, and only when the movement was clearly vertical. A tap never travels far enough
    /// to reach here.
    ///
    /// "Clearly vertical" is half, not most. A flick towards the next photograph that drifts
    /// downwards on the way is still a page turn, and throwing the picture away on one of
    /// those was the surprise.
    ///
    /// A third gesture wants it once the photograph is enlarged: panning. Being simultaneous,
    /// this one would fire on top of the pan and throw the picture away as the user pushed it
    /// down, so the caller masks it off for as long as the zoom is held.
    private var revealDetails: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let vertical = value.translation.height
                guard abs(vertical) > 72,
                      abs(value.translation.width) < abs(vertical) * 0.5 else { return }

                Haptics.impact(.soft)
                if vertical < 0 {
                    showDetails = true
                } else {
                    dismiss()
                }
            }
    }

    // MARK: Controls

    /// Back, the date and Mute, in three slots that do not move.
    ///
    /// The two side slots claim equal width and the date takes only what it needs in the
    /// middle, rather than three views separated by `Spacer`s. With spacers the capsule can
    /// grow — "Aug 8, 2026" at the largest accessibility size is wider than the space between
    /// two forty-six point buttons — and when it does it shoulders Back and Mute out of the
    /// corners the user reaches for without looking.
    private var topBar: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 0) {
                GlassIconButton(systemImage: "chevron.backward", label: "Back", tone: .clear) { dismiss() }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The moment it happened, not the day the file arrived — otherwise a clip saved
            // from a message would be labelled with the day it was saved.
            //
            // Flat, not glass, and never tappable: see `ViewerSurface`.
            if let record {
                Text(record.momentDate, format: .dateTime.month(.abbreviated).day().year())
                    .font(Typo.meta)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 7)
                    .viewerSurface(in: .capsule)
                    .allowsHitTesting(false)
                    // A caption pinned between two fixed buttons is furniture: there is
                    // nowhere for it to grow to.
                    .chromeTypeSize()
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if record?.isVideo == true {
                    // Sound sits at the top, away from the transport and away from the thumb
                    // resting at the bottom of the phone. It also fills what used to be an
                    // invisible 46-point square in this corner: `Color.clear` takes touches
                    // like any other view, so every tap aimed at the corner vanished into it.
                    GlassIconButton(systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    label: isMuted ? "Unmute" : "Mute",
                                    tone: .clear) {
                        toggleMute()
                    }
                } else {
                    Color.clear
                        .frame(width: 46, height: 46)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.s)
    }

    /// What sits directly above the button cluster: the transport for a video, the filmstrip
    /// for anything else. Never both.
    ///
    /// They used to be both, in the same band of the screen. The video's control strip was
    /// positioned by guessing how tall the viewer's own chrome was, and the guess was about
    /// thirty points short, so the filmstrip — drawn afterwards and therefore on top —
    /// answered every touch aimed at the scrubber underneath it. Two panes of clear glass
    /// overlapping look like one, which is why this never showed up in a screenshot.
    ///
    /// Whoever is in the slot, it is the same height. The strip and the transport are not the
    /// same size, and letting the slot follow its occupant moved the heart and the ••• menu up
    /// the screen every time a swipe crossed from a photograph to a clip — a button that walks
    /// away between one page and the next is a button you miss.
    @ViewBuilder
    private var bottomSlot: some View {
        if let player {
            VideoTransport(player: player, isPlaying: $isPlaying)
                // One transport per player, never a reused one handed a new player. The
                // observer it installs belongs to the player that issued it, and a view that
                // survived the swap would go on reporting the position of the clip before it.
                .id(ObjectIdentifier(player))
                .frame(height: slotHeight)
                .padding(.bottom, Space.s)
        } else if record?.isVideo == true {
            // Held open while the clip is still being fetched from the library, so the strip
            // does not appear for an instant and get swapped out from under a thumb that is
            // already moving towards it.
            //
            // It used to be held open and *empty*, which is the whole of what a clip stuck in
            // iCloud looked like: a poster frame, a band of nothing, and no end to it. What
            // is happening now goes in that band instead.
            videoStatusSlot
                .frame(height: slotHeight)
                .padding(.bottom, Space.s)
        } else if identifiers.count > 1, verticalSizeClass != .compact {
            // Scrubbing along the strip is how you cross a long memory without flicking
            // through it one photograph at a time. A set of one has nothing to scrub, and the
            // decision is taken here rather than left to the strip because the slot must
            // collapse with it — otherwise a single photograph opens with an empty band of
            // reserved space under it.
            //
            // It also goes away when the phone is on its side. Eighty points of thumbnails on
            // a screen that is under four hundred tall is a fifth of the photograph spent on
            // a shortcut for reaching a photograph, and the swipe that the strip is a
            // shortcut *for* still works. The transport is not dropped the same way: that one
            // is the only way to reach the middle of a clip.
            ViewerFilmstrip(identifiers: identifiers, current: $current)
                .frame(height: slotHeight)
                .padding(.bottom, Space.s)
        }
    }

    /// What the viewer can say about a clip it has not managed to play yet.
    ///
    /// Deliberately words rather than a bare spinner in the download case: a spinner over a
    /// still says "something is happening" and nothing else, and the honest answer — this
    /// video is not on the phone — is the one that tells the user whether waiting is worth it.
    @ViewBuilder
    private var videoStatusSlot: some View {
        switch videoLoad {
        case .idle:
            Color.clear.allowsHitTesting(false)
        case .downloading:
            HStack(spacing: Space.m) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Downloading from iCloud…")
                    .font(Typo.meta)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .viewerSurface(in: .capsule)
            .padding(.horizontal, Space.gutter)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Text(message)
                .font(Typo.meta)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .viewerSurface(in: .capsule)
                .padding(.horizontal, Space.gutter)
                .allowsHitTesting(false)
        }
    }

    private var bottomCluster: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 14) {
                GlassIconButton(systemImage: isLoved ? "heart.fill" : "heart",
                                label: isLoved ? "Remove from Loved" : "Love",
                                prominent: isLoved,
                                tone: .clear) {
                    toggleLoved()
                }

                Menu {
                    // "Open Photos", not "Show in Photos": see `openPhotos()`. iOS cannot be
                    // asked to land on one asset, and a button that promises it and delivers
                    // the app's front page is a button that does not work.
                    //
                    // Title case throughout, which is what the HIG asks of a menu and what
                    // every stock app does. This list used to mix the two conventions in one
                    // menu — "Show Similar Photos" beside "Save to a collection" — which reads
                    // as two people having written it.
                    Button("Open Photos", systemImage: "photo.on.rectangle.angled") { openPhotos() }
                    Button("Share", systemImage: "square.and.arrow.up") { Task { await prepareShare() } }
                    Button("Save to a Collection", systemImage: "plus.rectangle.on.folder") {
                        isSaving = true
                    }
                    Divider()
                    Button("Show Similar Photos", systemImage: "square.stack.3d.down.right") {
                        similarFor = current
                    }
                    Button("Show Event", systemImage: "calendar.badge.clock") { showEvent() }
                    Button("Show This Day", systemImage: "calendar") { showThisDay() }
                    Divider()
                    // Named for what it actually sets. This pins the cover of the *occasion*
                    // the photograph belongs to — where it shows up is the Places pins, the
                    // Best Of rows and trip covers. The memory the user is looking at re-elects
                    // its own cover through `Curator.cover`, so "Use as Cover" promised a
                    // change that was invisible exactly where it was made.
                    Button("Use as Occasion Cover", systemImage: "rectangle.inset.filled") { useAsCover() }
                    Button("Details", systemImage: "info.circle") { showDetails = true }
                    Divider()
                    Button("Hide from Memories", systemImage: "eye.slash", role: .destructive) {
                        hideFromMemories()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        // A glyph inside a control whose size is fixed by the cluster it lines
                        // up in. Growing it does not make it more legible, it makes it wider
                        // than the glass it sits on; the button's label is what serves a
                        // reader who needs larger text.
                        .font(Typo.glyph(17))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .frame(width: 46, height: 46)
                        .contentShape(.circle)
                }
                .glassControl(.circle, tone: .clear)
                .accessibilityLabel("More actions")
            }
        }
        // Twenty-eight points of air under the cluster is right below a home indicator on a
        // tall screen and a quarter of the remaining picture on a short one.
        .padding(.bottom, verticalSizeClass == .compact ? Space.m : Space.xl)
    }

    // MARK: Paging

    /// Everything that belonged to the photograph being left behind, put back before the next
    /// one arrives.
    ///
    /// All of it has outlived a page turn at one time or another: a heart still lit from the
    /// previous picture, a zoom that kept the pager switched off, a clip still playing out of
    /// sight with its sound on.
    /// Mute follows the stored preference once, when the viewer opens.
    ///
    /// It used to be re-read on every page turn, which meant a memory made of five clips asked
    /// the user to unmute five times: the tap was discarded the moment the page moved. Photos
    /// keeps the choice for as long as the viewer is open, and so does this.
    private func seedMute() {
        guard !hasSeededMute else { return }
        hasSeededMute = true
        isMuted = !app.settings.playAudio
    }

    private func settleOnCurrent() {
        zoom = ViewerZoom()
        lovedOverride = nil
        record = fetchRecord()
        videoLoad = .idle
        // A note belongs to the photograph it was about. Carried across a page turn it
        // becomes a claim about the wrong picture — and a failure message, which now has no
        // timer of its own, would otherwise sit there for the rest of the session.
        confirmation = nil
        releasePlayer()

        // Leaving a clip for a photograph is the moment to give the audio session back, and
        // the only moment: doing it in `releasePlayer` would hand it over and take it straight
        // back again on every swipe from one clip to the next, so the user's music would start
        // and stop between pages.
        if record?.isVideo != true { deactivateAudioSession() }
    }

    /// The slow half of arriving at a photograph, run behind a short pause.
    ///
    /// Dragging the filmstrip walks `current` through every photograph between where the
    /// finger started and where it is now. Asking Photos for a player item, reconciling the
    /// heart against the library and recording the photograph as seen for each one of those
    /// would spend the whole gesture starting work that is obsolete before it lands.
    /// `task(id:)` cancels the previous run on every change, so the pause only ever elapses
    /// for the photograph the user actually stopped on.
    private func loadCurrent() async {
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }

        app.feedback.recordAssetSeen([current])
        await reconcileLoved()
        await loadPlayer()
    }

    /// Fetch the clip, say so while it is being fetched, and say so if it never arrives.
    ///
    /// Every step of this used to be one link in a `guard` chain that returned silently, so a
    /// video living only in iCloud — or one the library simply refuses to hand over — left the
    /// viewer sitting on a poster frame forever with nothing on screen to explain it. Each
    /// failure now has a sentence, and the wait has a state.
    private func loadPlayer() async {
        guard let record, record.isVideo else { return }

        guard let asset = PhotoLibraryService.asset(for: current) else {
            failVideo("This video is no longer in your library")
            return
        }

        // The original may have to come down from iCloud first, which for a long 4K clip is
        // tens of seconds. The row already knows; the user did not.
        if !record.isLocallyAvailable {
            videoLoad = .downloading
            announce("Downloading this video from iCloud")
        }

        let item = await PhotoImageLoader.shared.playerItem(for: asset)
        guard !Task.isCancelled else { return }

        guard let item else {
            failVideo("Couldn’t load this video")
            return
        }

        // Wait for the item to have something to draw before the player is published.
        //
        // The page swaps the poster still for the player layer the instant `player` is set,
        // and that layer paints black until its first frame decodes — so every video opened
        // with a hard cut from a sharp still to pure black and back. Holding the still until
        // the item is ready is what Photos does, and it costs nothing when the clip is local
        // because the very first check usually passes.
        await waitUntilReady(item)
        guard !Task.isCancelled else { return }

        guard item.status != .failed else {
            failVideo("Couldn’t play this video")
            return
        }

        // The page showed the poster frame while this was loading, and a poster frame can be
        // pinched. Handing the picture over to a player that cannot zoom while the zoom is
        // still held would leave the pager switched off with no way to switch it back on.
        zoom = ViewerZoom()
        videoLoad = .idle

        let loaded = AVPlayer(playerItem: item)
        loaded.isMuted = isMuted
        // Stated rather than left to the default, so the playhead parks at the end instead of
        // the item being advanced out from under a transport that is still describing it.
        loaded.actionAtItemEnd = .pause
        configureAudioSession()
        player = loaded

        if app.settings.autoplayVideos {
            loaded.play()
            isPlaying = true
        }
    }

    /// A clip that will not play, said once and left on screen.
    ///
    /// The message lives in the transport's slot rather than in the passing banner, because
    /// this is a standing condition and not an event — but the slot is part of the chrome, so
    /// the chrome has to come back or a user who had tapped it away sees nothing at all.
    private func failVideo(_ message: String) {
        videoLoad = .failed(message)
        showControls = true
        announce(message)
    }

    /// Give the item a moment to reach a status, without blocking on one that never will.
    ///
    /// Polled rather than observed on purpose: the alternative is KVO plumbing around a value
    /// that is checked at most a few dozen times in the life of one clip, and the first check
    /// happens before any waiting at all, so a local video pays nothing for it. Three seconds
    /// is the ceiling — past that the player is handed over anyway and the transport reports
    /// whatever it finds, which is better than a viewer that waits forever.
    private func waitUntilReady(_ item: AVPlayerItem) async {
        for _ in 0..<60 {
            if item.status != .unknown { return }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
    }

    /// Video sound belongs to the video, not to the ringer switch.
    ///
    /// The app ran on the default session category, which is `.soloAmbient`: it obeys the
    /// physical silent switch, so tapping unmute with the switch flipped produced a video with
    /// no sound and no explanation, and it is not mixable, so a clip autoplaying — the default
    /// — stopped whatever the user was listening to even while muted. Both are answered by
    /// choosing the category against what is actually about to be heard: a muted clip stays
    /// out of everybody's way, an unmuted one behaves like a film.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        if isMuted {
            try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        } else {
            try? session.setCategory(.playback, mode: .moviePlayback)
        }
        try? session.setActive(true)
    }

    /// Hands the session back, and tells whoever was playing before that they can resume.
    ///
    /// Without the option the user's music stays stopped after the viewer closes, which is the
    /// half of the bug that outlives the screen that caused it.
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stop the picture and keep the button honest about it.
    private func pausePlayback() {
        guard player != nil else { return }
        player?.pause()
        isPlaying = false
    }

    /// Nothing is left playing behind the user.
    private func releasePlayer() {
        player?.pause()
        player = nil
        isPlaying = false
        // Never left disabled with no player to justify it: this setting belongs to the whole
        // device, and a viewer that forgets to put it back keeps the screen awake in every
        // other app the user opens afterwards.
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Everything the viewer is holding on to, let go of on the way out.
    private func leaveViewer() {
        releasePlayer()
        deactivateAudioSession()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Actions

    private func fetchRecord() -> AssetRecord? {
        LibraryQuery.records(for: [current], context: app.container.mainContext).first
    }

    /// Filled when either flag is set.
    ///
    /// `isLoved` is this app's own signal and `isFavoriteInPhotos` mirrors the asset, and the
    /// two only ever part company when Photos is edited elsewhere. A library favourited in
    /// Photos long before this app existed carries the second and not the first, and drawing
    /// all of it with an empty heart would be exactly the disagreement this button is meant to
    /// end.
    private var isLoved: Bool {
        if let lovedOverride { return lovedOverride }
        guard let record else { return false }
        return record.isLoved || record.isFavoriteInPhotos
    }

    private func toggleControls() {
        showControls.toggle()
    }

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        // Unmuting is what turns a clip from background noise nobody asked for into something
        // the user chose to listen to, so the session category has to change with it.
        if player != nil { configureAudioSession() }
        Haptics.impact(.light)
    }

    /// Zoom, from the rotor rather than from two fingers.
    ///
    /// The picture could only ever be enlarged by a pinch or a double tap, neither of which
    /// VoiceOver passes through, so the photograph was the one thing in this app a VoiceOver
    /// user could not look at closely. This is the same three-times step the double tap uses,
    /// centred rather than anchored on a point, because there is no point to anchor to.
    private func toggleZoomFromAccessibility() {
        if reduceMotion {
            flipZoom()
        } else {
            withAnimation(.smooth(duration: 0.28)) { flipZoom() }
        }
        announce(zoom.isZoomed ? "Zoomed in" : "Zoomed out")
    }

    private func flipZoom() {
        zoom = zoom.isZoomed ? ViewerZoom() : ViewerZoom(scale: 3)
    }

    /// The heart writes through to Photos, and says so when it cannot.
    ///
    /// The icon and the local rows move first so the gesture feels immediate; the library is
    /// the slow, fallible part and runs behind them. If it refuses, everything is put back and
    /// the reason is shown, because a heart that stays filled over a photograph Photos never
    /// favourited is worse than no heart at all.
    private func toggleLoved() {
        let next = !isLoved
        let target = current

        lovedOverride = next
        setLoved(next, identifier: target)
        Haptics.impact(.light)
        confirm(next ? "Loved" : "Removed")

        Task {
            guard let failure = await Loved.write(next, identifier: target) else { return }
            setLoved(!next, identifier: target)
            // The user may have moved on while the library was thinking. The row above is
            // theirs wherever they are, but the icon and the message belong to this page.
            guard target == current else { return }
            lovedOverride = !next
            confirm(failure.message, isFailure: true)
        }
    }

    /// Both local flags at once: the app's own signal, which the ranking learns from, and its
    /// mirror of `PHAsset.isFavorite`, so the details panel and the Loved filter agree with the
    /// heart immediately instead of whenever the next indexing pass happens to notice.
    private func setLoved(_ loved: Bool, identifier: String) {
        app.feedback.setLoved(loved, identifier: identifier)

        let context = app.container.mainContext
        guard let record = LibraryQuery.records(for: [identifier], context: context).first else { return }
        record.isFavoriteInPhotos = loved
        context.saveIfNeeded()
    }

    /// Believe the library over the local row when the two disagree.
    ///
    /// The row is only as fresh as the last indexing pass, so a photograph favourited in the
    /// Photos app a minute ago would open here with an empty heart. A tap that has already
    /// landed on this page outranks this, hence the check on the override — otherwise a
    /// reconciliation still in flight when the user hearts the picture would undo it.
    private func reconcileLoved() async {
        let target = current
        guard let favorite = await Loved.libraryFavorite(identifier: target),
              lovedOverride == nil else { return }

        let context = app.container.mainContext
        guard let record = LibraryQuery.records(for: [target], context: context).first,
              record.isLoved != favorite || record.isFavoriteInPhotos != favorite else { return }
        record.isLoved = favorite
        record.isFavoriteInPhotos = favorite
        context.saveIfNeeded()
    }

    /// Hidden from Memories, not deleted. The photo stays exactly where it is in Photos.
    private func hideFromMemories() {
        app.feedback.setHiddenFromMemories(true, identifier: current)
        Haptics.impact()
        confirm("Hidden from Memories")
    }

    /// Every path out of here says something.
    ///
    /// The occasion can have been rewritten out from under this photograph — re-clustering
    /// replaces the whole table — and without the last branch the menu item simply closed and
    /// produced nothing at all: no cover, no confirmation, no error. Every other branch of
    /// this menu explains itself; this one used to be the exception.
    private func useAsCover() {
        guard let record, let eventID = record.eventClusterID else {
            confirm("No occasion for this photo", isFailure: true)
            return
        }
        let context = app.container.mainContext
        var descriptor = FetchDescriptor<EventCluster>(predicate: #Predicate { $0.id == eventID })
        descriptor.fetchLimit = 1
        if let event = try? context.fetch(descriptor).first {
            event.coverIdentifier = current
            context.saveIfNeeded()
            confirm("Set as occasion cover")
        } else {
            confirm("That occasion is no longer in your library", isFailure: true)
        }
    }

    private func showEvent() {
        guard let record, record.eventClusterID != nil else {
            confirm("This photo isn’t part of an occasion", isFailure: true)
            return
        }
        eventFor = current
    }

    private func showThisDay() {
        guard let record else { return }
        let components = Calendar.current.dateComponents([.month, .day], from: record.momentDate)
        guard let month = components.month, let day = components.day else { return }
        dayWindow = .dayAcrossYears(month: month, day: day)
    }

    /// Open the Photos app.
    ///
    /// Deliberately not "show this photograph in Photos", and the menu item is worded to match:
    /// iOS has no public way to hand another app a `PHAsset` and be taken to it. The only
    /// documented door is `photos-redirect://`, which opens Photos and nothing more; the
    /// scheme Photos uses internally, `photos-navigation://`, will open a named album and
    /// takes a `revealassetuuid`, but it is undocumented and has never been shown to land
    /// reliably on a single asset.
    ///
    /// So the reveal is attempted first as a courtesy — a `localIdentifier` is `UUID/L0/001`
    /// and Photos addresses an asset by the UUID in front — and `photos-redirect://` catches
    /// it when the system will not take it. Whatever happens, the user ends up in Photos,
    /// which is exactly and only what the button says it does.
    private func openPhotos() {
        let uuid = current.components(separatedBy: "/").first ?? current
        let photos = URL(string: "photos-redirect://")

        guard let reveal = URL(string: "photos-navigation://album?name=recents&revealassetuuid=\(uuid)") else {
            if let photos { UIApplication.shared.open(photos) }
            return
        }

        UIApplication.shared.open(reveal) { opened in
            guard !opened, let photos else { return }
            UIApplication.shared.open(photos)
        }
    }

    /// Share the thing the user is looking at, not a picture of it.
    ///
    /// This always asked for a `UIImage`, whatever it was pointed at, so sharing a clip sent a
    /// 2048-pixel poster frame — and the share sheet completed happily, showing an image
    /// preview, so nobody found out until the person on the other end did. A video is now
    /// exported and shared as a file.
    private func prepareShare() async {
        if record?.isVideo == true {
            await shareVideo()
        } else {
            await shareStill()
        }
    }

    private func shareStill() async {
        guard let image = await PhotoImageLoader.shared.image(
            forIdentifier: current,
            targetSize: CGSize(width: 2048, height: 2048),
            purpose: .display
        ) else {
            confirm("Couldn’t load this photo", isFailure: true)
            return
        }
        sharing = ShareRequest(items: [image])
    }

    /// The clip itself, as a file.
    ///
    /// `requestAVAsset` hands back whatever the library has; only a `AVURLAsset` has something
    /// that can be put in a share sheet, and a composition — a slo-mo clip, or one with an
    /// edit applied — does not. Rather than silently falling back to a still, that case says
    /// so, because the whole point of this change is that the user is told what they sent.
    private func shareVideo() async {
        guard let asset = PhotoLibraryService.asset(for: current) else {
            confirm("This video is no longer in your library", isFailure: true)
            return
        }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current

        let url: URL? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }

        guard let url else {
            confirm("Couldn’t prepare this video to share", isFailure: true)
            return
        }
        sharing = ShareRequest(items: [url])
    }

    /// A note about what just happened, said out loud as well as drawn.
    ///
    /// Drawn alone it was invisible to anyone using VoiceOver — the banner is not in the
    /// touch path, so exploration can never land on it — which meant that when Photos refused
    /// to love a photograph, the heart quietly flipped back and the only explanation appeared
    /// and vanished unseen. Bad news also stops having a timer: a second and a half is a
    /// receipt's lifetime, not an error's, and it can be dismissed with a tap or by turning
    /// the page.
    private func confirm(_ text: String, isFailure: Bool = false) {
        confirmation = Confirmation(text: text, isFailure: isFailure)
        announce(text)
        guard !isFailure else { return }

        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if confirmation?.text == text { confirmation = nil }
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

// MARK: - Surfaces

/// The flat surface every control in the viewer that carries text or fine detail sits on.
///
/// It is not glass, and that is the whole point of it. Liquid Glass works by bending what is
/// behind it, and behind a control in here there is either a photograph or — wherever the
/// picture does not reach — pure black. Over black there is nothing to refract, so all that
/// survives of the material is the specular highlight along its top edge, and on a wide
/// straight-edged panel that draws as a hard white line across an otherwise dark slab. On the
/// device it reads as a rendering fault rather than as a material, and it is a fair part of
/// what the controls over video were being called.
///
/// So the viewer keeps two vocabularies rather than one. Round glyph buttons stay glass: a
/// specular rim on a circle is what Liquid Glass looks like everywhere else in iOS, and it
/// reads as a material because it is one. Anything wide and straight-edged — the filmstrip,
/// the video transport, the date, a confirmation — is this instead, which is honest over black
/// and keeps white type legible over a bright photograph. `Palette.photoScrim` is the same
/// idea at the weight used under content that is already opaque; this one is heavier because
/// small white text has to survive on it.
enum ViewerSurface {
    static let fill = Color.black.opacity(0.55)

    /// The same surface, answering the two settings that exist because of it.
    ///
    /// Forty-five per cent of an arbitrary photograph still shows through behind eleven-point
    /// white type, which is precisely the situation Increase Contrast and Reduce Transparency
    /// are switched on to end. Neither used to reach here. It stays a black wash either way —
    /// no material, no tint, no colour the system did not already have — it simply stops being
    /// see-through when the reader has said they do not want it to be.
    static func weight(increaseContrast: Bool, reduceTransparency: Bool) -> Color {
        if reduceTransparency { return .black }
        return increaseContrast ? Color.black.opacity(0.85) : fill
    }
}

extension View {
    /// Backs a caption, a banner or a strip in the viewer with `ViewerSurface`, at whatever
    /// weight the reader's settings call for.
    ///
    /// A modifier rather than a colour, because the two values it needs come from the
    /// environment and a `static let` cannot read the environment — which is exactly how the
    /// old constant came to ignore both settings everywhere it was used.
    func viewerSurface<S: Shape>(in shape: S) -> some View {
        modifier(ViewerSurfaceModifier(shape: shape))
    }
}

private struct ViewerSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(
            ViewerSurface.weight(increaseContrast: contrast == .increased,
                                 reduceTransparency: reduceTransparency),
            in: shape
        )
    }
}

// MARK: - Zoom

/// How far into the still on screen the viewer is currently zoomed.
///
/// This is held by the viewer rather than by the page that draws it, because the two things
/// that most need to know about it live outside the picture: the pager, which has to stop
/// paging while a photograph is enlarged, and the vertical drag, which has to stop meaning
/// "leave" while it means "pan". It is cleared when a different photograph arrives.
struct ViewerZoom: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    /// A hair above fit, so a pinch that lands back where it started does not leave the pager
    /// switched off.
    var isZoomed: Bool { scale > 1.01 }
}

// MARK: - One page

/// Draws whichever kind of asset this is, natively: a still, a real Live Photo, or a video.
///
/// Every branch answers a tap on itself. That is the whole reason the viewer above has no tap
/// gesture of its own: one finger on the picture must reach exactly one gesture, and the only
/// way to guarantee that is for the view that draws the picture to be the view that owns it.
private struct ViewerPage: View {
    let identifier: String
    let isCurrent: Bool
    /// Only ever set for the photograph on screen. The pages either side show their poster
    /// frame instead, which is what they would have shown anyway while a player loaded.
    let player: AVPlayer?
    @Binding var zoom: ViewerZoom
    let onSurfaceTap: () -> Void
    let onDetails: () -> Void
    let onClose: () -> Void
    let onToggleZoom: () -> Void

    @Environment(\.app) private var app
    @State private var livePhoto: PHLivePhoto?

    /// What this page is, in a sentence, for a reader who cannot see it.
    ///
    /// The full-screen photograph was the largest thing in the app and the only one that said
    /// nothing at all: VoiceOver announced an unlabelled image and left the user to guess
    /// whether they had reached a photograph, a clip, or the wrong one entirely.
    @State private var spokenDescription = "Photo"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let player {
                    MemoryVideoPlayer(player: player, onSurfaceTap: onSurfaceTap)
                } else if let livePhoto {
                    LivePhotoView(livePhoto: livePhoto,
                                  isPlaying: isCurrent && app.settings.playLivePhotos,
                                  onTap: onSurfaceTap)
                } else {
                    ZoomableStill(identifier: identifier,
                                  size: proxy.size,
                                  zoom: $zoom,
                                  onSurfaceTap: onSurfaceTap)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // One element for the whole picture, and every gesture on it named.
        //
        // Swipe up for details, swipe down to leave and double tap to zoom were the three
        // things this screen could do, and all three were distances travelled by a finger —
        // which VoiceOver consumes for its own navigation. Named actions put them on the rotor
        // without changing anything for anyone else.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription)
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "Details") { onDetails() }
        .accessibilityAction(named: zoom.isZoomed ? "Zoom out" : "Zoom in") { onToggleZoom() }
        .accessibilityAction(named: "Show controls") { onSurfaceTap() }
        .accessibilityAction(named: "Close") { onClose() }
        // Keyed on whether this is the photograph being looked at, not only on which one it
        // is. `prepare` used to run for every page the pager realised, so opening a memory
        // whose neighbours live in iCloud began downloading full-quality Live Photos for
        // pictures nobody had reached — over cellular, and with no way to cancel them.
        .task(id: preparationKey) { await prepare() }
    }

    private var preparationKey: String { isCurrent ? identifier : "" }

    /// The pager recycles these pages, so whatever the last photograph left behind is cleared
    /// before the next one is asked for. Without that, a page that had held a Live Photo and
    /// came back holding an ordinary still went on playing the Live Photo.
    private func prepare() async {
        livePhoto = nil

        guard let record = LibraryQuery.records(for: [identifier],
                                                context: app.container.mainContext).first else { return }
        spokenDescription = Self.describe(record)

        guard isCurrent,
              record.isLivePhoto,
              app.settings.playLivePhotos,
              let asset = PhotoLibraryService.asset(for: identifier) else { return }

        let size = CGSize(width: 1600, height: 1600)
        livePhoto = await PhotoImageLoader.shared.livePhoto(for: asset, targetSize: size)
    }

    /// "Video, 41 seconds, 12 March 2024" — what it is, how long it runs, when it happened.
    ///
    /// The duration goes through `Duration`'s unit style rather than the `0:41` the badges
    /// show, because a clock face read aloud is a string of numbers with no unit attached to
    /// them, and the date through the system's abbreviated style so both follow the locale.
    private static func describe(_ record: AssetRecord) -> String {
        let date = record.momentDate.formatted(date: .abbreviated, time: .omitted)
        if record.isVideo {
            let length = Duration.seconds(Int(record.duration.rounded()))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            return "Video, \(length), \(date)"
        }
        if record.isLivePhoto { return "Live Photo, \(date)" }
        if record.isScreenshot { return "Screenshot, \(date)" }
        return "Photo, \(date)"
    }
}

/// A still you can pinch and double tap into, the first thing anyone tries on a photograph.
///
/// Only stills get this. A video has a player under the finger and a Live Photo is played by
/// `PHLivePhotoView`, which owns its own touches.
///
/// Both taps live here, on one view, larger count first — that is the order SwiftUI resolves
/// them in. They used to be two levels apart, the double tap on the picture and the single tap
/// on the pager above it, which is a pairing nothing arbitrates.
///
/// The drags are more delicate. The pager runs underneath and the viewer's vertical drag runs
/// above, so nothing here claims a touch it does not need: the pan is masked out entirely at
/// fit scale, which leaves the pager exactly as it was, and only comes alive once the picture
/// is bigger than the screen. The pinch is simultaneous so that a second finger never has to
/// fight the pan for the touch.
private struct ZoomableStill: View {
    let identifier: String
    let size: CGSize
    @Binding var zoom: ViewerZoom
    let onSurfaceTap: () -> Void

    /// Where the picture stood when the gesture now running began. Both gestures report a
    /// total measured from their own start, so without a fixed base every event would
    /// compound on the one before it.
    @State private var pinchBase: ViewerZoom?
    @State private var panBase: PanBase?

    /// A double tap scales and translates a full-bleed photograph across the whole screen,
    /// which is the largest single piece of motion in the app and the first thing anyone tries
    /// on a picture. Under Reduce Motion the zoom still happens — the picture simply arrives
    /// at the new scale instead of travelling to it.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct PanBase {
        let offset: CGSize
        let translation: CGSize
    }

    private let maxScale: CGFloat = 6
    private let tapScale: CGFloat = 3

    var body: some View {
        PhotoImageView(identifier: identifier,
                       targetSide: size.width,
                       purpose: .display,
                       contentMode: .fit)
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .frame(width: size.width, height: size.height)
            // The gestures hang off the untransformed page-sized frame rather than off the
            // picture, so a tap reports where it landed in the same coordinates the offsets
            // are written in, however far the picture has been pushed.
            .contentShape(.rect)
            .onTapGesture(count: 2, coordinateSpace: .local) { location in toggleZoom(at: location) }
            .onTapGesture { onSurfaceTap() }
            .gesture(pan, including: zoom.isZoomed ? .all : .subviews)
            .simultaneousGesture(pinch)
    }

    // MARK: Gestures

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? zoom
                pinchBase = base
                // Dropping the pan's base every frame is what keeps a second finger from
                // dragging the picture around underneath the pinch: the pan re-measures from
                // where things already are and so contributes nothing until the pinch ends.
                panBase = nil

                // Under fit is allowed while the fingers are down so the picture gives a
                // little; `settle` takes it back on release.
                let scale = min(max(base.scale * value.magnification, 0.6), maxScale)
                zoom = ViewerZoom(scale: scale, offset: anchored(value.startAnchor, from: base, to: scale))
            }
            .onEnded { _ in
                pinchBase = nil
                settle()
            }
    }

    /// A distance rather than nothing, so a still finger is read as a tap and never as a pan.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let base = panBase ?? PanBase(offset: zoom.offset, translation: value.translation)
                panBase = base
                let moved = CGSize(width: base.offset.width + value.translation.width - base.translation.width,
                                   height: base.offset.height + value.translation.height - base.translation.height)
                zoom.offset = bounded(moved, at: zoom.scale)
            }
            .onEnded { _ in panBase = nil }
    }

    private func toggleZoom(at location: CGPoint) {
        Haptics.impact(.light)
        if reduceMotion {
            applyZoom(at: location)
        } else {
            withAnimation(.smooth(duration: 0.28)) { applyZoom(at: location) }
        }
    }

    private func applyZoom(at location: CGPoint) {
        guard !zoom.isZoomed else {
            zoom = ViewerZoom()
            return
        }
        let fromCentre = CGSize(width: location.x - size.width / 2, height: location.y - size.height / 2)
        let centred = CGSize(width: -fromCentre.width * tapScale, height: -fromCentre.height * tapScale)
        zoom = ViewerZoom(scale: tapScale, offset: bounded(centred, at: tapScale))
    }

    // MARK: Arithmetic

    /// Keeps the point the fingers started on under the fingers, so the picture grows out of
    /// where it was grabbed rather than out of its middle.
    private func anchored(_ anchor: UnitPoint, from base: ViewerZoom, to scale: CGFloat) -> CGSize {
        let x = (anchor.x - 0.5) * size.width
        let y = (anchor.y - 0.5) * size.height
        return bounded(CGSize(width: base.offset.width + x * (base.scale - scale),
                              height: base.offset.height + y * (base.scale - scale)),
                       at: scale)
    }

    /// Stops the picture being pushed out from under the finger. The slack is measured from
    /// the page rather than from the photograph because the photograph's own proportions are
    /// not known here; at fit scale there is none, and past it there is more the further in
    /// you go.
    private func bounded(_ offset: CGSize, at scale: CGFloat) -> CGSize {
        let slackX = max(0, size.width * (scale - 1) / 2)
        let slackY = max(0, size.height * (scale - 1) / 2)
        return CGSize(width: min(max(offset.width, -slackX), slackX),
                      height: min(max(offset.height, -slackY), slackY))
    }

    private func settle() {
        let scale = min(max(zoom.scale, 1), maxScale)
        if reduceMotion {
            applySettled(scale)
        } else {
            withAnimation(.smooth(duration: 0.24)) { applySettled(scale) }
        }
    }

    private func applySettled(_ scale: CGFloat) {
        zoom = ViewerZoom(scale: scale, offset: scale > 1 ? bounded(zoom.offset, at: scale) : .zero)
    }
}

/// `PHLivePhotoView` has no SwiftUI equivalent, and the point is to use the real thing
/// rather than approximate it with a looping video.
private struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isPlaying: Bool
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        // The chrome toggle is added as a recognizer on the live photo view itself rather than
        // as a SwiftUI tap on a transparent layer above it. A layer above would have to be
        // hit-testable to receive the tap, and it would then swallow press-and-hold as well —
        // which is the one gesture a Live Photo exists for.
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.handleTap)))
        return view
    }

    /// Playback is driven by the *change*, never by the current value.
    ///
    /// `updateUIView` runs on every re-render of the viewer, and `isPlaying` is true for the
    /// whole time a Live Photo is on screen — so toggling the chrome, hearting the picture or
    /// the confirmation banner appearing and going away again all called `startPlayback` once
    /// more and yanked the Live Photo back to its first frame, with its audio. Remembering
    /// what was last asked for makes it happen once.
    ///
    /// `.hint` rather than `.full` for that automatic play: the hint is the short "this one
    /// moves" flourish Photos shows on arrival, and it leaves press-and-hold — which
    /// `PHLivePhotoView` handles by itself, and which is the entire point of a Live Photo — to
    /// the user.
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onTap = onTap
        if view.livePhoto != livePhoto {
            view.livePhoto = livePhoto
            context.coordinator.isPlaying = false
        }
        guard isPlaying != context.coordinator.isPlaying else { return }
        context.coordinator.isPlaying = isPlaying
        if isPlaying { view.startPlayback(with: .hint) } else { view.stopPlayback() }
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        /// What playback state this view was last *told* to be in, which is not the same as
        /// what it is in — the hint finishes on its own.
        var isPlaying = false

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap() {
            onTap()
        }
    }
}

// MARK: - Sharing

struct SharePayload: Identifiable {
    let image: UIImage
    var id: String { String(UInt(bitPattern: ObjectIdentifier(image).hashValue)) }
}

/// Whatever the viewer is sharing, which is not always an image.
///
/// A separate type from `SharePayload` because a payload built around a `UIImage` cannot carry
/// a file URL, and a video has to be shared as a file or it is not a video.
struct ShareRequest: Identifiable {
    let items: [Any]
    let id = UUID()
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    /// The popover has to be told where it is coming from, whether or not it ends up being one.
    ///
    /// In regular width UIKit resolves `UIActivityViewController` to a popover, and a popover
    /// presented with neither a source view nor a bar button item does not fall back to
    /// anything — it raises, at presentation time, which is a crash. Share is reached from the
    /// viewer's menu, a grid's context menu and the batch bar, so all three were an immediate
    /// crash on iPad the moment the app was allowed to run as one.
    ///
    /// Anchored to its own view with no arrow, it presents centred, which is the right shape
    /// for a share sheet that was not invoked from a particular button.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX,
                                        y: controller.view.bounds.midY,
                                        width: 1,
                                        height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
