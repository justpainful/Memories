import AVKit
import PhotosUI
import SwiftData
import SwiftUI

/// Full screen. The photograph is the whole screen and the only thing on it.
///
/// Controls are one floating glass cluster that gets out of the way after a moment and comes
/// back on a tap. Nothing is layered over the image permanently, and there is no story
/// progress bar counting down at the user.
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
    @State private var confirmationText: String?

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
                    ViewerPage(identifier: identifier, isCurrent: identifier == current)
                        .tag(identifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { toggleControls() }

            if showControls {
                VStack {
                    topBar
                    Spacer()
                    bottomCluster
                }
                .transition(.opacity)
            }

            if let confirmationText {
                Text(confirmationText)
                    .font(Typo.control)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .glassPanel(cornerRadius: 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .statusBarHidden(!showControls)
        .animation(.smooth(duration: 0.28), value: showControls)
        .animation(.smooth(duration: 0.25), value: confirmationText)
        .onAppear { scheduleHide() }
        .onChange(of: current) { _, _ in
            app.feedback.recordAssetSeen([current])
            scheduleHide()
        }
        .sheet(isPresented: $showDetails) {
            AssetDetailsView(identifier: current)
                .presentationDetents([.medium, .large])
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
    }

    // MARK: Controls

    private var topBar: some View {
        HStack {
            GlassIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            if let record { Text(record.creationDate, format: .dateTime.month(.abbreviated).day().year())
                .font(Typo.meta)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, Space.m)
                .padding(.vertical, 7)
                .glassPanel(cornerRadius: 14)
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
                                prominent: isLoved) {
                    toggleLoved()
                }

                Menu {
                    Button("Show in Photos", systemImage: "photo.on.rectangle.angled") { openPhotos() }
                    Button("Share", systemImage: "square.and.arrow.up") { Task { await prepareShare() } }
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
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 46, height: 46)
                }
                .glassControl(.circle)
                .accessibilityLabel("More actions")
            }
        }
        .padding(.bottom, Space.xl)
    }

    // MARK: Actions

    private var record: AssetRecord? {
        LibraryQuery.records(for: [current], context: app.container.mainContext).first
    }

    private var isLoved: Bool { record?.isLoved ?? false }

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

    private func toggleLoved() {
        let next = !isLoved
        app.feedback.setLoved(next, identifier: current)
        Haptics.impact(.light)
        confirm(next ? "Loved" : "Removed")
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
        let components = Calendar.current.dateComponents([.month, .day], from: record.creationDate)
        guard let month = components.month, let day = components.day else { return }
        dayWindow = .dayAcrossYears(month: month, day: day)
    }

    /// There is no public API to deep-link a specific asset, so this opens Photos itself.
    private func openPhotos() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
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

// MARK: - One page

/// Draws whichever kind of asset this is, natively: a still, a real Live Photo, or a video.
private struct ViewerPage: View {
    let identifier: String
    let isCurrent: Bool

    @Environment(\.app) private var app
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var record: AssetRecord?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { if app.settings.autoplayVideos && isCurrent { player.play() } }
                        .onDisappear { player.pause() }
                } else if let livePhoto {
                    LivePhotoView(livePhoto: livePhoto, isPlaying: isCurrent && app.settings.playLivePhotos)
                } else {
                    PhotoImageView(identifier: identifier,
                                   targetSide: proxy.size.width,
                                   purpose: .display,
                                   contentMode: .fit)
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
