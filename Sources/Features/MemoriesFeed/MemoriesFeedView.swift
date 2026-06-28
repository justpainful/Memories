import AVKit
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct MemoriesFeedView: View {
    @State private var playbackCoordinator: MemoryPlaybackCoordinator
    @State private var currentIdentifier: String?
    @State private var shareRoute: MemoryShareRoute?

    @Binding private var filter: MemoryFilter

    private let candidates: [MemoryCandidate]
    private let sharingClient: MediaSharingClient
    private let actionHandler: MemoryFeedActionHandler

    init(
        candidates: [MemoryCandidate],
        filter: Binding<MemoryFilter>,
        playbackCoordinator: MemoryPlaybackCoordinator,
        sharingClient: MediaSharingClient,
        actionHandler: MemoryFeedActionHandler = .init()
    ) {
        _filter = filter
        _playbackCoordinator = State(initialValue: playbackCoordinator)
        self.candidates = candidates
        self.sharingClient = sharingClient
        self.actionHandler = actionHandler
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportSize = geometry.size

            ZStack(alignment: .top) {
                feedScrollView(viewportSize: viewportSize)
                feedChrome(viewportSize: viewportSize)
            }
            .background(Color.black.ignoresSafeArea())
            .task {
                await playbackCoordinator.configure()
                await activateInitialCandidateIfNeeded(viewportSize: viewportSize)
            }
            .onChange(of: candidates.map(\.localIdentifier)) { _, _ in
                Task {
                    await activateInitialCandidateIfNeeded(viewportSize: viewportSize)
                }
            }
            .onChange(of: currentIdentifier) { _, newValue in
                guard let newValue, let candidate = candidates.first(where: { $0.localIdentifier == newValue }) else {
                    return
                }

                actionHandler.onDisplay(candidate)

                Task {
                    await playbackCoordinator.activate(
                        candidate: candidate,
                        in: candidates,
                        targetSize: viewportSize
                    )
                }
            }
            .sheet(item: $shareRoute, onDismiss: {
                Task {
                    await sharingClient.cleanupExpiredTemporaryFiles()
                }
            }) { route in
                MemoryShareSheet(activityItems: [route.url])
            }
        }
    }

    @ViewBuilder
    private func feedScrollView(viewportSize: CGSize) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    MemoryFeedPage(
                        candidate: candidate,
                        presentation: playbackCoordinator.presentation(for: candidate),
                        isActive: currentIdentifier == candidate.localIdentifier,
                        isSaved: candidate.status == .saved,
                        isMuted: playbackCoordinator.isMuted,
                        isLoading: playbackCoordinator.isPreparing && currentIdentifier == candidate.localIdentifier,
                        lastError: playbackCoordinator.lastError,
                        onShare: { Task { await prepareShare(for: candidate) } },
                        onToggleMuted: { Task { await playbackCoordinator.toggleMuted() } },
                        onSave: { actionHandler.onSave(candidate) },
                        onBlock: { actionHandler.onBlock(candidate) }
                    )
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .background(
                        GeometryReader { pageGeometry in
                            Color.clear.preference(
                                key: MemoryFeedPageDistancePreferenceKey.self,
                                value: [
                                    candidate.localIdentifier:
                                        abs(pageGeometry.frame(in: .named(MemoryFeedCoordinateSpace.name)).midY - (viewportSize.height / 2))
                                ]
                            )
                        }
                    )
                    .id(candidate.localIdentifier)
                }
            }
            .scrollTargetLayout()
        }
        .coordinateSpace(name: MemoryFeedCoordinateSpace.name)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .ignoresSafeArea()
        .onPreferenceChange(MemoryFeedPageDistancePreferenceKey.self) { distances in
            currentIdentifier = distances.min(by: { $0.value < $1.value })?.key
        }
    }

    @ViewBuilder
    private func feedChrome(viewportSize: CGSize) -> some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 0) {
                MemoryExploreBar(filter: $filter)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)

                Spacer()

                HStack {
                    Spacer()
                    MemoryActionCluster(
                        isMuted: playbackCoordinator.isMuted,
                        isSaved: currentCandidate?.status == .saved,
                        onShare: {
                            guard let currentCandidate else { return }
                            Task { await prepareShare(for: currentCandidate) }
                        },
                        onToggleMuted: { Task { await playbackCoordinator.toggleMuted() } },
                        onSave: {
                            guard let currentCandidate else { return }
                            actionHandler.onSave(currentCandidate)
                        },
                        onBlock: {
                            guard let currentCandidate else { return }
                            actionHandler.onBlock(currentCandidate)
                        }
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, max(24, viewportSize.height * 0.08))
                }
            }
        }
    }

    private var currentCandidate: MemoryCandidate? {
        guard let currentIdentifier else { return candidates.first }
        return candidates.first(where: { $0.localIdentifier == currentIdentifier })
    }

    private func activateInitialCandidateIfNeeded(viewportSize: CGSize) async {
        guard !candidates.isEmpty else { return }

        let initialCandidate = currentCandidate ?? candidates[0]
        currentIdentifier = initialCandidate.localIdentifier
        await playbackCoordinator.activate(candidate: initialCandidate, in: candidates, targetSize: viewportSize)
    }

    private func prepareShare(for candidate: MemoryCandidate) async {
        do {
            let url = try await sharingClient.prepareShareURL(for: candidate)
            shareRoute = MemoryShareRoute(candidate: candidate, url: url)
        } catch {
            actionHandler.onShareError(error)
        }
    }
}

struct MemoryFeedActionHandler {
    var onSave: (MemoryCandidate) -> Void = { _ in }
    var onBlock: (MemoryCandidate) -> Void = { _ in }
    var onShareError: (Error) -> Void = { _ in }
    var onDisplay: (MemoryCandidate) -> Void = { _ in }
}

private enum MemoryFeedCoordinateSpace {
    static let name = "memories-feed-scroll"
}

private struct MemoryFeedPageDistancePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MemoryShareRoute: Identifiable {
    let candidate: MemoryCandidate
    let url: URL

    var id: String {
        candidate.localIdentifier
    }
}

private struct MemoryFeedPage: View {
    let candidate: MemoryCandidate
    let presentation: MemoryPlaybackPresentation?
    let isActive: Bool
    let isSaved: Bool
    let isMuted: Bool
    let isLoading: Bool
    let lastError: Error?
    let onShare: () -> Void
    let onToggleMuted: () -> Void
    let onSave: () -> Void
    let onBlock: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MemoryRenderableSurface(
                candidate: candidate,
                presentation: presentation,
                isActive: isActive,
                isMuted: isMuted
            )

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            MemoryFeedCaption(candidate: candidate)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(20)
            }

            if !isLoading, presentation == nil, lastError != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                    Text("This memory could not be prepared.")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("memories-feed-item-\(candidate.localIdentifier)")
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("Share", systemImage: "square.and.arrow.up", action: onShare)
            Button("Mute", systemImage: "speaker.slash", action: onToggleMuted)
            Button("Save", systemImage: "bookmark", action: onSave)
            Button("Block", systemImage: "eye.slash", role: .destructive, action: onBlock)
        }
    }
}

private struct MemoryFeedCaption: View {
    let candidate: MemoryCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(captionTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                Label(candidate.mediaKind.label, systemImage: candidate.mediaKind.symbolName)
                if let duration = candidate.duration, candidate.mediaKind == .video {
                    Label(duration.formattedDuration, systemImage: "play.rectangle")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captionTitle: String {
        guard let creationDate = candidate.creationDate else {
            return "Undated memory"
        }

        return creationDate.formatted(.dateTime.month(.wide).day().year())
    }
}

private struct MemoryActionCluster: View {
    let isMuted: Bool
    let isSaved: Bool
    let onShare: () -> Void
    let onToggleMuted: () -> Void
    let onSave: () -> Void
    let onBlock: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                actionButton(systemName: "square.and.arrow.up", label: "Share", action: onShare)
                actionButton(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: isMuted ? "Unmute" : "Mute", action: onToggleMuted)
                actionButton(systemName: isSaved ? "bookmark.fill" : "bookmark", label: "Save", action: onSave)
                actionButton(systemName: "eye.slash", label: "Block", action: onBlock)
            }
        }
    }

    private func actionButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .semibold))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .frame(width: 74, height: 74)
        }
        .modifier(MemoryActionButtonStyleModifier())
        .accessibilityLabel(label)
    }
}

private struct MemoryExploreBar: View {
    @Binding var filter: MemoryFilter

    private let presets = MemoryExplorePreset.allCases
    private let mediaKindOrder = MediaKind.allCases
    private let yearOptions = Array((Calendar.current.component(.year, from: Date()) - 10)...Calendar.current.component(.year, from: Date())).reversed()

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label("Explore", systemImage: "slider.horizontal.3")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset.title) {
                            filter.preset = preset
                        }
                    }

                    Divider()

                    Button("Clear preset") {
                        filter.preset = nil
                    }
                } label: {
                    Label(filter.preset?.title ?? "All memories", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.white)
                .accessibilityIdentifier("memories-feed-explore-control")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(mediaKindOrder, id: \.self) { mediaKind in
                        let isSelected = filter.mediaKinds.contains(mediaKind)
                        Button {
                            toggle(mediaKind)
                        } label: {
                                    Label(mediaKind.label, systemImage: mediaKind.symbolName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(.white)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(isSelected ? 0.18 : 0.08))
                                )
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Menu {
                        Button("Smart Random") { filter.selectionMode = .smartRandom }
                        Button("Pure Random") { filter.selectionMode = .pureRandom }
                    } label: {
                        filterChipTitle(
                            title: filter.selectionMode == .smartRandom ? "Smart Random" : "Pure Random",
                            systemImage: filter.selectionMode == .smartRandom ? "sparkles" : "shuffle"
                        )
                    }

                    Menu {
                        Button("Any year") { filter.yearFrom = nil }
                        ForEach(yearOptions, id: \.self) { year in
                            Button("\(year)") { filter.yearFrom = year }
                        }
                    } label: {
                        filterChipTitle(title: "From \(filter.yearFrom.map(String.init) ?? "Any")", systemImage: "calendar")
                    }

                    Menu {
                        Button("Any year") { filter.yearTo = nil }
                        ForEach(yearOptions, id: \.self) { year in
                            Button("\(year)") { filter.yearTo = year }
                        }
                    } label: {
                        filterChipTitle(title: "To \(filter.yearTo.map(String.init) ?? "Any")", systemImage: "calendar")
                    }

                    Button {
                        filter.includesScreenshots.toggle()
                    } label: {
                        filterChipTitle(
                            title: filter.includesScreenshots ? "Screenshots On" : "Screenshots Off",
                            systemImage: "photo.on.rectangle"
                        )
                    }

                    Button {
                        filter.includesScreenRecordings.toggle()
                    } label: {
                        filterChipTitle(
                            title: filter.includesScreenRecordings ? "Recordings On" : "Recordings Off",
                            systemImage: "record.circle"
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(MemoryExploreGlassModifier())
    }

    private func toggle(_ mediaKind: MediaKind) {
        if filter.mediaKinds.contains(mediaKind) {
            filter.mediaKinds.remove(mediaKind)
            if filter.mediaKinds.isEmpty {
                filter.mediaKinds = Set(MediaKind.allCases)
            }
        } else {
            filter.mediaKinds.insert(mediaKind)
        }
    }

    private func filterChipTitle(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
    }
}

private struct MemoryExploreGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.tint(.white.opacity(0.08)).interactive(), in: .rect(cornerRadius: 22))
    }
}

private struct MemoryActionButtonStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.glass)
    }
}

extension MediaKind {
    var label: String {
        switch self {
        case .photo:
            "Photos"
        case .video:
            "Videos"
        case .livePhoto:
            "Live"
        }
    }

    var symbolName: String {
        switch self {
        case .photo:
            "photo"
        case .video:
            "video"
        case .livePhoto:
            "livephoto"
        }
    }
}

private extension MemoryExplorePreset {
    var title: String {
        switch self {
        case .thisWeekAcrossYears:
            "This week"
        case .previousWeekAcrossYears:
            "Previous week"
        case .nextWeekAcrossYears:
            "Next week"
        case .onThisDay:
            "On this day"
        case .randomFromEntireLibrary:
            "Random library"
        }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let duration = Duration.seconds(self)
        return duration.formatted(.time(pattern: .minuteSecond))
    }
}

@MainActor
@Observable
final class MemoriesFeedFilterState {
    var filter: MemoryFilter

    init(filter: MemoryFilter = .default) {
        self.filter = filter
    }
}

@MainActor
struct MemoriesFeedRootView: View {
    @State private var filterState: MemoriesFeedFilterState
    @State private var playbackCoordinator: MemoryPlaybackCoordinator

    private let candidates: [MemoryCandidate]
    private let sharingClient: MediaSharingClient
    private let actionHandler: MemoryFeedActionHandler

    init(
        candidates: [MemoryCandidate],
        filterState: MemoriesFeedFilterState = MemoriesFeedFilterState(),
        playbackCoordinator: MemoryPlaybackCoordinator,
        sharingClient: MediaSharingClient,
        actionHandler: MemoryFeedActionHandler = .init()
    ) {
        _filterState = State(initialValue: filterState)
        _playbackCoordinator = State(initialValue: playbackCoordinator)
        self.candidates = candidates
        self.sharingClient = sharingClient
        self.actionHandler = actionHandler
    }

    init(
        candidates: [MemoryCandidate],
        photoLibrary: PhotoLibraryClient,
        sharingClient: MediaSharingClient,
        initialFilter: MemoryFilter = .default,
        muteCoordinator: PlaybackCoordinating = ProcessPlaybackCoordinator.shared,
        actionHandler: MemoryFeedActionHandler = .init()
    ) {
        self.init(
            candidates: candidates,
            filterState: MemoriesFeedFilterState(filter: initialFilter),
            playbackCoordinator: .appCoordinator(photoLibrary: photoLibrary, muteCoordinator: muteCoordinator),
            sharingClient: sharingClient,
            actionHandler: actionHandler
        )
    }

    var body: some View {
        @Bindable var bindableFilterState = filterState

        MemoriesFeedView(
            candidates: candidates,
            filter: $bindableFilterState.filter,
            playbackCoordinator: playbackCoordinator,
            sharingClient: sharingClient,
            actionHandler: actionHandler
        )
    }
}
