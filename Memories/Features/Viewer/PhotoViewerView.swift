import AVKit
import PhotosUI
import SwiftData
import SwiftUI

/// Full screen. The photograph is the whole screen and the only thing on it.
///
/// Controls are one floating glass cluster that gets out of the way after a moment and comes
/// back on a tap. Nothing is layered over the image permanently, and there is no story
/// progress bar counting down at the user.
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
    @State private var hideTask: Task<Void, Never>?
    @State private var showDetails = false
    @State private var shareImage: UIImage?
    @State private var similarFor: String?
    @State private var eventFor: String?
    @State private var dayWindow: TimeWindow?
    @State private var isSaving = false
    @State private var confirmationText: String?
    @State private var zoom = ViewerZoom()

    /// What the heart is showing while the tap is still in flight, and `nil` whenever it is
    /// simply showing what is stored.
    ///
    /// Loving a photograph has to reach the Photos library, which takes a moment and can be
    /// refused, so the icon cannot wait for it — but it also must not lie about it. This is
    /// set the instant the finger lands and put back if the library says no. Keeping it apart
    /// from the stored value is also what stops the picture arriving with the previous
    /// photograph's heart still lit.
    @State private var lovedOverride: Bool?

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
                               showControls: showControls,
                               zoom: identifier == current ? $zoom : .constant(ViewerZoom()),
                               onSurfaceTap: { toggleControls() })
                        .tag(identifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { toggleControls() }
            .simultaneousGesture(revealDetails, including: zoom.isZoomed ? .subviews : .all)

            if showControls {
                VStack {
                    topBar
                    Spacer()
                    // Scrubbing along the strip is how you cross a long memory without
                    // flicking through it one photograph at a time.
                    ViewerFilmstrip(identifiers: identifiers, current: $current)
                        .padding(.bottom, Space.s)
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
                    .glassPanel(cornerRadius: 20, tone: .clear)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .statusBarHidden(!showControls)
        // The zoom transition brings a pull-to-dismiss of its own with it. That is welcome at
        // fit scale, but while the photograph is enlarged a downward drag means panning, and
        // the presentation would otherwise take the gesture away mid-pan.
        .interactiveDismissDisabled(zoom.isZoomed)
        .animation(.smooth(duration: 0.28), value: showControls)
        .animation(.smooth(duration: 0.25), value: confirmationText)
        .onAppear { scheduleHide() }
        .onChange(of: current) { _, _ in
            zoom = ViewerZoom()
            lovedOverride = nil
            app.feedback.recordAssetSeen([current])
            scheduleHide()
        }
        // Off the main actor and cancelled when the page turns, because scrubbing the
        // filmstrip changes `current` many times a second and each of these is a hit on the
        // Photos database.
        .task(id: current) { await reconcileLoved() }
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
    /// Swipe-down-to-dismiss matters more than it looks. The controls fade after a couple of
    /// seconds, and a full-screen cover has no interactive dismiss of its own, so without this
    /// the only way out of a photograph is a button that is no longer on screen — you have to
    /// know to tap first. Photos has always let you throw the picture away downward, and the
    /// gesture is what people reach for.
    ///
    /// Two other gestures already want this touch: the pager's horizontal scroll and the tap
    /// that toggles the controls. So this runs *simultaneously* rather than competing — it
    /// never claims the touch while the finger is down, and decides only once the finger
    /// lifts, and only when the movement was clearly vertical. A horizontal flick still turns
    /// the page, and a tap never travels far enough to reach here.
    ///
    /// A third gesture wants it once the photograph is enlarged: panning. Being simultaneous,
    /// this one would fire on top of the pan and throw the picture away as the user pushed it
    /// down, so the caller masks it off for as long as the zoom is held.
    private var revealDetails: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let vertical = value.translation.height
                guard abs(vertical) > 60,
                      abs(value.translation.width) < abs(vertical) * 0.6 else { return }

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
            if let record { Text(record.momentDate, format: .dateTime.month(.abbreviated).day().year())
                .font(Typo.meta)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, Space.m)
                .padding(.vertical, 7)
                .glassPanel(cornerRadius: 14, tone: .clear)
            }
            Spacer()
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.s)
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
                }
                .glassControl(.circle, tone: .clear)
                .accessibilityLabel("More actions")
            }
        }
        .padding(.bottom, Space.xl)
    }

    // MARK: Actions

    private var record: AssetRecord? {
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
        if showControls { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            showControls = false
        }
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
private struct ViewerPage: View {
    let identifier: String
    let isCurrent: Bool
    let showControls: Bool
    @Binding var zoom: ViewerZoom
    let onSurfaceTap: () -> Void

    @Environment(\.app) private var app
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var record: AssetRecord?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let player {
                    MemoryVideoPlayer(player: player,
                                      showControls: showControls,
                                      autoplay: app.settings.autoplayVideos && isCurrent,
                                      onSurfaceTap: onSurfaceTap)
                } else if let livePhoto {
                    LivePhotoView(livePhoto: livePhoto, isPlaying: isCurrent && app.settings.playLivePhotos)
                } else {
                    ZoomableStill(identifier: identifier, size: proxy.size, zoom: $zoom)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: identifier) { await prepare() }
    }

    private func prepare() async {
        record = LibraryQuery.records(for: [identifier], context: app.container.mainContext).first
        guard let record, let asset = PhotoLibraryService.asset(for: identifier) else { return }

        if record.isVideo {
            if let item = await PhotoImageLoader.shared.playerItem(for: asset) {
                let player = AVPlayer(playerItem: item)
                player.isMuted = !app.settings.playAudio
                self.player = player
            }
        } else if record.isLivePhoto, app.settings.playLivePhotos {
            let size = CGSize(width: 1600, height: 1600)
            livePhoto = await PhotoImageLoader.shared.livePhoto(for: asset, targetSize: size)
        }
    }
}

/// A still you can pinch and double tap into, the first thing anyone tries on a photograph.
///
/// Only stills get this. A video has its own controls under the finger and a Live Photo is
/// played by `PHLivePhotoView`, which owns its own touches.
///
/// Three gestures already run on this touch — the pager underneath, the tap that toggles the
/// controls, and the viewer's vertical drag — so nothing here is allowed to claim a touch it
/// does not need. The pan is masked out entirely at fit scale, which leaves the pager exactly
/// as it was; it only comes alive once the picture is bigger than the screen, and from then
/// on it wins the horizontal drag because it sits below the pager in the hierarchy. The pinch
/// is simultaneous so that a second finger never has to fight the pan for the touch.
private struct ZoomableStill: View {
    let identifier: String
    let size: CGSize
    @Binding var zoom: ViewerZoom

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

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto != livePhoto { view.livePhoto = livePhoto }
        if isPlaying { view.startPlayback(with: .full) } else { view.stopPlayback() }
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
