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

    @State private var current: String
    @State private var showControls = true
    @State private var showDetails = false
    @State private var shareImage: UIImage?
    @State private var similarFor: String?
    @State private var eventFor: String?
    @State private var dayWindow: TimeWindow?
    @State private var isSaving = false
    @State private var confirmationText: String?
    @State private var zoom = ViewerZoom()

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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $current) {
                ForEach(identifiers, id: \.self) { identifier in
                    ViewerPage(identifier: identifier,
                               isCurrent: identifier == current,
                               player: identifier == current ? player : nil,
                               zoom: identifier == current ? $zoom : .constant(ViewerZoom()),
                               onSurfaceTap: { toggleControls() })
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

            if let confirmationText {
                Text(confirmationText)
                    .font(Typo.control)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .background(ViewerSurface.fill, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    // A note about what just happened must never be the thing that eats the
                    // next tap. This sits in the middle of the picture for a second and a half,
                    // right where the finger is.
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(!showControls)
        // The zoom transition brings a pull-to-dismiss of its own with it. That is welcome at
        // fit scale, but while the photograph is enlarged a downward drag means panning, and
        // the presentation would otherwise take the gesture away mid-pan.
        .interactiveDismissDisabled(zoom.isZoomed)
        .animation(.smooth(duration: 0.28), value: showControls)
        .animation(.smooth(duration: 0.25), value: confirmationText)
        .onAppear { settleOnCurrent() }
        .onDisappear { releasePlayer() }
        .onChange(of: current) { _, _ in settleOnCurrent() }
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
        }
        .sheet(isPresented: $showDetails) {
            AssetDetailsView(identifier: current)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { similarFor.map(ViewerRequest.init(identifier:)) },
            set: { similarFor = $0?.identifier }
        )) { request in
            SimilarPhotosView(identifier: request.identifier)
        }
        .sheet(item: Binding(
            get: { shareImage.map(SharePayload.init(image:)) },
            set: { shareImage = $0?.image }
        )) { payload in
            ShareSheet(items: [payload.image])
        }
        .sheet(item: Binding(
            get: { eventFor.map(ViewerRequest.init(identifier:)) },
            set: { eventFor = $0?.identifier }
        )) { request in
            EventSheet(identifier: request.identifier)
        }
        .sheet(item: $dayWindow) { window in
            TimeWindowResultsView(window: window)
        }
        .sheet(isPresented: $isSaving) {
            AddToCollectionSheet(
                items: [CollectionItem(kind: .asset, reference: current)],
                suggestedCover: current
            ) { name in
                confirm("Kept in \(name)")
            }
            .presentationDetents([.medium, .large])
        }
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

    private var topBar: some View {
        HStack {
            GlassIconButton(systemImage: "chevron.left", label: "Back", tone: .clear) { dismiss() }
            Spacer()
            // The moment it happened, not the day the file arrived — otherwise a clip saved
            // from a message would be labelled with the day it was saved.
            //
            // Flat, not glass, and never tappable: see `ViewerSurface`.
            if let record {
                Text(record.momentDate, format: .dateTime.month(.abbreviated).day().year())
                    .font(Typo.meta)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 7)
                    .background(ViewerSurface.fill, in: .capsule)
                    .allowsHitTesting(false)
            }
            Spacer()
            if record?.isVideo == true {
                // Sound sits at the top, away from the transport and away from the thumb
                // resting at the bottom of the phone. It also fills what used to be an
                // invisible 46-point square in this corner: `Color.clear` takes touches like
                // any other view, so every tap aimed at the corner vanished into it.
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
            Color.clear
                .frame(height: slotHeight)
                .padding(.bottom, Space.s)
                .allowsHitTesting(false)
        } else if identifiers.count > 1 {
            // Scrubbing along the strip is how you cross a long memory without flicking
            // through it one photograph at a time. A set of one has nothing to scrub, and the
            // decision is taken here rather than left to the strip because the slot must
            // collapse with it — otherwise a single photograph opens with an empty band of
            // reserved space under it.
            ViewerFilmstrip(identifiers: identifiers, current: $current)
                .frame(height: slotHeight)
                .padding(.bottom, Space.s)
        }
    }

    private var bottomCluster: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 14) {
                GlassIconButton(systemImage: isLoved ? "heart.fill" : "heart",
                                label: isLoved ? "Remove from loved" : "Love",
                                prominent: isLoved,
                                tone: .clear) {
                    toggleLoved()
                }

                Menu {
                    // "Open Photos", not "Show in Photos": see `openPhotos()`. iOS cannot be
                    // asked to land on one asset, and a button that promises it and delivers
                    // the app's front page is a button that does not work.
                    Button("Open Photos", systemImage: "photo.on.rectangle.angled") { openPhotos() }
                    Button("Share", systemImage: "square.and.arrow.up") { Task { await prepareShare() } }
                    Button("Save to a collection", systemImage: "plus.rectangle.on.folder") {
                        isSaving = true
                    }
                    Divider()
                    Button("Show Similar Photos", systemImage: "square.stack.3d.down.right") {
                        similarFor = current
                    }
                    Button("Show Event", systemImage: "calendar.badge.clock") { showEvent() }
                    Button("Show This Day", systemImage: "calendar") { showThisDay() }
                    Divider()
                    Button("Use as Cover", systemImage: "rectangle.inset.filled") { useAsCover() }
                    Button("Details", systemImage: "info.circle") { showDetails = true }
                    Divider()
                    Button("Hide from Memories", systemImage: "eye.slash", role: .destructive) {
                        hideFromMemories()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .frame(width: 46, height: 46)
                        .contentShape(.circle)
                }
                .glassControl(.circle, tone: .clear)
                .accessibilityLabel("More actions")
            }
        }
        .padding(.bottom, Space.xl)
    }

    // MARK: Paging

    /// Everything that belonged to the photograph being left behind, put back before the next
    /// one arrives.
    ///
    /// All of it has outlived a page turn at one time or another: a heart still lit from the
    /// previous picture, a zoom that kept the pager switched off, a clip still playing out of
    /// sight with its sound on.
    private func settleOnCurrent() {
        zoom = ViewerZoom()
        lovedOverride = nil
        isMuted = !app.settings.playAudio
        record = fetchRecord()
        releasePlayer()
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

    private func loadPlayer() async {
        guard let record, record.isVideo,
              let asset = PhotoLibraryService.asset(for: current),
              let item = await PhotoImageLoader.shared.playerItem(for: asset),
              !Task.isCancelled else { return }

        // The page showed the poster frame while this was loading, and a poster frame can be
        // pinched. Handing the picture over to a player that cannot zoom while the zoom is
        // still held would leave the pager switched off with no way to switch it back on.
        zoom = ViewerZoom()

        let loaded = AVPlayer(playerItem: item)
        loaded.isMuted = isMuted
        player = loaded

        if app.settings.autoplayVideos {
            loaded.play()
            isPlaying = true
        }
    }

    /// Nothing is left playing behind the user.
    private func releasePlayer() {
        player?.pause()
        player = nil
        isPlaying = false
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
        Haptics.impact(.light)
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
            confirm(failure.message)
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

    private func useAsCover() {
        guard let record, let eventID = record.eventClusterID else {
            confirm("No event for this photo")
            return
        }
        let context = app.container.mainContext
        var descriptor = FetchDescriptor<EventCluster>(predicate: #Predicate { $0.id == eventID })
        descriptor.fetchLimit = 1
        if let event = try? context.fetch(descriptor).first {
            event.coverIdentifier = current
            context.saveIfNeeded()
            confirm("Set as cover")
        }
    }

    private func showEvent() {
        guard let record, record.eventClusterID != nil else {
            confirm("This photo isn't part of an occasion")
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

    private func prepareShare() async {
        guard let image = await PhotoImageLoader.shared.image(
            forIdentifier: current,
            targetSize: CGSize(width: 2048, height: 2048),
            purpose: .display
        ) else {
            confirm("Could not load this photo")
            return
        }
        shareImage = image
    }

    private func confirm(_ text: String) {
        confirmationText = text
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if confirmationText == text { confirmationText = nil }
        }
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

    @Environment(\.app) private var app
    @State private var livePhoto: PHLivePhoto?

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
        .task(id: identifier) { await prepare() }
    }

    /// The pager recycles these pages, so whatever the last photograph left behind is cleared
    /// before the next one is asked for. Without that, a page that had held a Live Photo and
    /// came back holding an ordinary still went on playing the Live Photo.
    private func prepare() async {
        livePhoto = nil

        guard let record = LibraryQuery.records(for: [identifier],
                                                context: app.container.mainContext).first,
              record.isLivePhoto,
              app.settings.playLivePhotos,
              let asset = PhotoLibraryService.asset(for: identifier) else { return }

        let size = CGSize(width: 1600, height: 1600)
        livePhoto = await PhotoImageLoader.shared.livePhoto(for: asset, targetSize: size)
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
        withAnimation(.smooth(duration: 0.28)) {
            guard !zoom.isZoomed else {
                zoom = ViewerZoom()
                return
            }
            let fromCentre = CGSize(width: location.x - size.width / 2, height: location.y - size.height / 2)
            let centred = CGSize(width: -fromCentre.width * tapScale, height: -fromCentre.height * tapScale)
            zoom = ViewerZoom(scale: tapScale, offset: bounded(centred, at: tapScale))
        }
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
        withAnimation(.smooth(duration: 0.24)) {
            zoom = ViewerZoom(scale: scale, offset: scale > 1 ? bounded(zoom.offset, at: scale) : .zero)
        }
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

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onTap = onTap
        if view.livePhoto != livePhoto { view.livePhoto = livePhoto }
        if isPlaying { view.startPlayback(with: .full) } else { view.stopPlayback() }
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void

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

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
