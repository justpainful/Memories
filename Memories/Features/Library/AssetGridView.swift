import SwiftData
import SwiftUI
import UIKit

/// The square grid used by every "show me these photos" screen.
///
/// One implementation so the tap target, corner radius, badges and full-screen hand-off
/// behave identically everywhere, rather than drifting screen by screen.
struct AssetGridView: View {
    let records: [AssetRecord]
    var emptyTitle: String = "Nothing here"
    var emptyDetail: String?
    var emptySymbol: String = "photo.on.rectangle"
    /// Extra control shown on each tile, e.g. Restore on the Hidden screen.
    var trailingAction: ((AssetRecord) -> AnyView)?

    @Environment(\.app) private var app
    /// Ties a tile to the photograph it opens, so the thumbnail grows into the full screen and
    /// shrinks back into itself instead of the viewer sliding up out of the bottom edge.
    @Namespace private var opening
    @State private var viewing: String?
    @State private var similarFor: String?
    @State private var savingFor: String?
    @State private var shareImage: UIImage?
    @State private var selection = PhotoSelection()
    @State private var loveFailure: String?
    @State private var prefetcher = GridPrefetcher()

    var body: some View {
        // Mapped once per redraw, not once per tile. `onAppear` fires for every cell that
        // scrolls in, and rebuilding this inside each of those would cost more than the
        // prefetching it feeds ever saves.
        let identifiers = records.map(\.localIdentifier)

        return Group {
            if records.isEmpty {
                QuietStatusView(title: emptyTitle, detail: emptyDetail, symbol: emptySymbol)
            } else {
                PhotoGrid {
                    ForEach(Array(records.enumerated()), id: \.element.localIdentifier) { index, record in
                        Button {
                            // While selecting, a tap picks rather than opens — the same tile,
                            // two meanings, which is how Photos does it too.
                            if selection.isActive {
                                selection.toggle(record.localIdentifier)
                            } else {
                                viewing = record.localIdentifier
                            }
                        } label: {
                            tile(record)
                                .selectionOverlay(
                                    isSelecting: selection.isActive,
                                    isSelected: selection.contains(record.localIdentifier),
                                    cornerRadius: 6
                                )
                        }
                        .buttonStyle(.plain)
                        // Tell Photos what is coming before it is asked for. Without this every
                        // tile is a cold request issued at the moment it appears.
                        .onAppear {
                            prefetcher.tileAppeared(at: index,
                                                    identifiers: identifiers,
                                                    side: 240)
                        }
                        // Holding a tile to reach its menu would fight picking it, so the menu
                        // steps aside for as long as selection is running.
                        .contextMenu(menuItems: {
                            if !selection.isActive { actions(for: record) }
                        }, preview: {
                            preview(record)
                        })
                        .matchedTransitionSource(id: record.localIdentifier, in: opening)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive {
                SelectionActionBar(selection: selection)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: selection.isActive)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.isActive ? "Done" : "Select") {
                        if selection.isActive { selection.end() } else { selection.begin() }
                        Haptics.selection()
                    }
                }
                // The count replaces the title only while selecting. Setting `navigationTitle`
                // here instead would mean owning it always, and this view does not know what
                // the screen around it is called.
                if selection.isActive {
                    ToolbarItem(placement: .principal) {
                        Text(selection.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewing.map(ViewerRequest.init(identifier:)) },
            set: { viewing = $0?.identifier }
        )) { request in
            PhotoViewerView(identifiers: records.map(\.localIdentifier), startAt: request.identifier)
                .navigationTransition(.zoom(sourceID: request.identifier, in: opening))
        }
        .sheet(item: Binding(
            get: { similarFor.map(ViewerRequest.init(identifier:)) },
            set: { similarFor = $0?.identifier }
        )) { request in
            SimilarPhotosView(identifier: request.identifier)
        }
        .sheet(item: Binding(
            get: { savingFor.map(ViewerRequest.init(identifier:)) },
            set: { savingFor = $0?.identifier }
        )) { request in
            AddToCollectionSheet(
                items: [CollectionItem(kind: .asset, reference: request.identifier)],
                suggestedCover: request.identifier
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { shareImage.map(SharePayload.init(image:)) },
            set: { shareImage = $0?.image }
        )) { payload in
            ShareSheet(items: [payload.image])
        }
        // Rare, and worth interrupting for: the heart has just been put back, so without this
        // the tile would silently undo what the user asked for.
        .alert("Couldn't love that photo",
               isPresented: Binding(get: { loveFailure != nil },
                                    set: { if !$0 { loveFailure = nil } })) {
            Button("OK", role: .cancel) { loveFailure = nil }
        } message: {
            Text(loveFailure ?? "")
        }
        // Photos should not be left decoding ahead for a grid that is no longer on screen.
        .onDisappear { prefetcher.stop() }
    }

    private func tile(_ record: AssetRecord) -> some View {
        PhotoImageView(identifier: record.localIdentifier, targetSide: 240)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if record.isVideo || record.isLivePhoto {
                    MediaBadge(record: record).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let trailingAction {
                    trailingAction(record).padding(4)
                } else if record.isLoved {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
    }

    // MARK: Holding a thumbnail

    /// The same actions the viewer's ••• menu offers, minus the ones that only mean something
    /// once the photograph is open. Holding a tile in Photos is how people reach these; making
    /// them open the picture first to love or hide it is a step Photos does not ask for.
    @ViewBuilder
    private func actions(for record: AssetRecord) -> some View {
        Button(record.isLoved ? "Remove from loved" : "Love",
               systemImage: record.isLoved ? "heart.slash" : "heart") {
            toggleLoved(record)
        }
        Button("Share", systemImage: "square.and.arrow.up") {
            Task { await prepareShare(record) }
        }
        Button("Save to a collection", systemImage: "plus.rectangle.on.folder") {
            savingFor = record.localIdentifier
        }
        Divider()
        Button("Show Similar Photos", systemImage: "square.stack.3d.down.right") {
            similarFor = record.localIdentifier
        }
        // On the Hidden screen every photograph is already out, and an action that changes
        // nothing is worse than an action that is absent.
        if !record.excludedFromMemories {
            Divider()
            Button("Hide from Memories", systemImage: "eye.slash", role: .destructive) {
                hide(record)
            }
        }
    }

    /// The photograph itself, larger. A preview showing anything else would be answering a
    /// question nobody asked by holding a picture.
    ///
    /// `PhotoImageView` fills whatever it is given and has no size of its own, so the frame
    /// has to carry the shape of the photograph — otherwise every preview comes out square,
    /// which is exactly what the thumbnail already was. The ratio is clamped so a panorama
    /// or a very tall portrait cannot produce a preview the screen has no room for.
    private func preview(_ record: AssetRecord) -> some View {
        let width: CGFloat = 320
        let ratio = CGFloat(min(max(record.aspectRatio, 0.6), 2.2))
        return PhotoImageView(identifier: record.localIdentifier,
                              targetSide: width * 2,
                              purpose: .display,
                              contentMode: .fit)
            .frame(width: width, height: width / ratio)
    }

    /// The same heart as the viewer's, and it has to reach the same place.
    ///
    /// Loving from the grid used to set the local flag only, so the identical gesture meant two
    /// different things depending on which screen it was made from — and only one of them
    /// showed up in Photos.
    private func toggleLoved(_ record: AssetRecord) {
        let loved = !record.isLoved
        app.feedback.setLoved(loved, identifier: record.localIdentifier)
        Haptics.impact(.light)

        Task {
            guard let failure = await Loved.write(loved, identifier: record.localIdentifier)
            else { return }
            // Put it back rather than leave the grid claiming something the library refused.
            app.feedback.setLoved(!loved, identifier: record.localIdentifier)
            loveFailure = failure.message
        }
    }

    /// Hidden from Memories, not deleted. The photo stays exactly where it is in Photos.
    private func hide(_ record: AssetRecord) {
        app.feedback.setHiddenFromMemories(true, identifier: record.localIdentifier)
        Haptics.impact()
    }

    /// The share sheet needs the real image, not the thumbnail already on screen, so this
    /// waits for a full-size load. If the original cannot be fetched — an iCloud asset with
    /// no network — nothing opens, which is quieter than a share sheet holding a blank.
    private func prepareShare(_ record: AssetRecord) async {
        shareImage = await PhotoImageLoader.shared.image(
            forIdentifier: record.localIdentifier,
            targetSize: CGSize(width: 2048, height: 2048),
            purpose: .display
        )
    }
}

/// A screen that is just a titled grid of one slice of the library.
struct AssetCollectionScreen: View {
    let title: String
    let records: [AssetRecord]
    var emptyTitle: String = "Nothing here yet"
    var emptyDetail: String?

    var body: some View {
        ScrollView {
            AssetGridView(records: records, emptyTitle: emptyTitle, emptyDetail: emptyDetail)
                .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
