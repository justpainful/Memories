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
    /// True while the screen is still fetching. Kept apart from "there is nothing here",
    /// because a grid that announces an empty library for the half second it takes to read
    /// fifteen thousand rows, then fills, reads as a bug rather than as loading.
    var isLoading = false
    /// Extra control shown on each tile, e.g. Restore on the Hidden screen.
    var trailingAction: ((AssetRecord) -> AnyView)?
    /// The selection this grid picks into, when the screen around it wants to own it.
    ///
    /// The batch bar has to be pinned to the screen, and only the view that owns the scroll
    /// view can pin anything to it — declared in here the bar lands at the end of the scrolled
    /// content, which on a grid of fifteen thousand photographs means scrolling to the bottom
    /// of the library to reach the buttons. A screen that passes its own selection draws the
    /// bar with `.selectionActionBar(_:)`; one that does not keeps the old behaviour.
    var selection: PhotoSelection?

    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// Ties a tile to the photograph it opens, so the thumbnail grows into the full screen and
    /// shrinks back into itself instead of the viewer sliding up out of the bottom edge.
    @Namespace private var opening
    @State private var viewing: String?
    @State private var similarFor: String?
    @State private var savingFor: String?
    @State private var shareImage: UIImage?
    @State private var ownSelection = PhotoSelection()
    @State private var loveFailure: String?
    @State private var shareFailure: String?
    @State private var prefetcher = GridPrefetcher()

    /// The same density key `PhotoGrid` reads, for the same reason it reads it: this view has to
    /// know how big a tile is coming out before it can ask Photos for one that size.
    @AppStorage(PhotoGridDensity.storageKey) private var storedColumns = PhotoGridDensity.standard
    /// The width this grid was handed, which is not the width of the device.
    @State private var gridWidth: CGFloat = Adaptive.referenceWidth

    /// Whichever selection is in force: the host's if it took it on, otherwise this grid's own.
    private var picking: PhotoSelection { selection ?? ownSelection }

    /// How wide one photograph is actually being drawn, right now.
    ///
    /// Everything that asks Photos for a bitmap has to agree on this number. It used to be
    /// written as a literal 240 in two places, which was true at one density on one screen:
    /// `PhotoImageView` requests `max(its own side, targetSide)` and `GridPrefetcher` warms at
    /// exactly what it is told, so the moment a tile was not 240 points the warmed bitmap was
    /// the wrong size and the cache served nothing. The prefetcher paid for a decode and the
    /// grid still arrived cold — worst on the widest screens, where the tiles are largest and
    /// the mismatch greatest.
    ///
    /// Derived rather than measured because `PhotoGrid` computes it from exactly these three
    /// values, and reading them again here is cheaper than plumbing a preference back out of a
    /// lazy grid mid-scroll.
    private var tileSide: CGFloat {
        let density = PhotoGridDensity.rung(nearest: storedColumns)
        let columns = Adaptive.gridColumns(density: density, width: gridWidth)
        let spacing = PhotoGridDensity.spacing(for: density)
        // The grid pads by one spacing on each side and puts one between every pair of columns.
        let chrome = spacing * CGFloat(columns + 1)
        return max(44, (gridWidth - chrome) / CGFloat(max(1, columns)))
    }

    var body: some View {
        // Mapped once per redraw, not once per tile. `onAppear` fires for every cell that
        // scrolls in, and rebuilding this inside each of those would cost more than the
        // prefetching it feeds ever saves.
        let identifiers = records.map(\.localIdentifier)

        return Group {
            if records.isEmpty {
                // Nothing at all while the fetch is in flight. Photos shows an empty grid
                // rather than a spinner, and saying anything here would be saying it wrongly.
                if isLoading {
                    Color.clear.frame(height: 1)
                } else {
                    QuietStatusView(title: emptyTitle, detail: emptyDetail, symbol: emptySymbol)
                }
            } else {
                PhotoGrid {
                    ForEach(Array(records.enumerated()), id: \.element.localIdentifier) { index, record in
                        cell(record, at: index, within: identifiers)
                    }
                }
            }
        }
        // The width the grid was handed, which is what `tileSide` is derived from. Read with
        // `onGeometryChange` rather than a `GeometryReader`: a reader wrapped round a lazy grid
        // claims all the space offered in both directions and collapses the scrolled height.
        .measuringWidth($gridWidth)
        // Only for a screen that has not taken the bar on itself. Here it is part of the
        // scrolling content and travels with it; see `selection` above.
        .safeAreaInset(edge: .bottom) {
            if selection == nil, picking.isActive {
                SelectionActionBar(selection: picking)
                    .transition(reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: picking.isActive)
        .toolbar {
            if !records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(picking.isActive ? "Done" : "Select") {
                        if picking.isActive { picking.end() } else { picking.begin() }
                        Haptics.selection()
                    }
                }
                // The count replaces the title only while selecting. Setting `navigationTitle`
                // here instead would mean owning it always, and this view does not know what
                // the screen around it is called.
                if picking.isActive {
                    ToolbarItem(placement: .principal) {
                        Text(picking.title)
                            // `.headline` rather than a fixed seventeen points: this shares a
                            // bar with a Select/Done button that grows with the reader's text
                            // size, and a principal item neither wraps nor gives way. At the
                            // largest sizes "1,247 Photos Selected" would push Done off the
                            // bar, leaving no way out of selection mode — so it is allowed to
                            // shrink instead.
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(Palette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
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
        .alert("Couldn’t love that photo",
               isPresented: Binding(get: { loveFailure != nil },
                                    set: { if !$0 { loveFailure = nil } })) {
            Button("OK", role: .cancel) { loveFailure = nil }
        } message: {
            Text(loveFailure ?? "")
        }
        // Share used to fail silently here — on a library kept on Optimize iPhone Storage the
        // loader returns nothing, no sheet opened, and from the user's side the menu item was
        // simply broken. The viewer and the batch bar both say so; the grid was the odd one out.
        .alert("Couldn’t share that photo",
               isPresented: Binding(get: { shareFailure != nil },
                                    set: { if !$0 { shareFailure = nil } })) {
            Button("OK", role: .cancel) { shareFailure = nil }
        } message: {
            Text(shareFailure ?? "")
        }
        // Photos should not be left decoding ahead for a grid that is no longer on screen.
        .onDisappear { prefetcher.stop() }
    }

    /// One photograph in the grid.
    ///
    /// Lifted out of `body`, and not for tidiness. A `Button` carrying a label, a selection
    /// overlay, four accessibility modifiers, a rotor action set, a corner overlay, an
    /// appearance hook, a context menu with its own preview and a transition source is one
    /// expression deep enough that the type checker gives up on the whole screen — which is
    /// exactly what it did, by name, in CI. A function signature is somewhere for it to stop
    /// and be certain.
    @ViewBuilder
    private func cell(_ record: AssetRecord, at index: Int, within identifiers: [String]) -> some View {
        Button {
            // While selecting, a tap picks rather than opens — the same tile,
            // two meanings, which is how Photos does it too.
            if picking.isActive {
                picking.toggle(record.localIdentifier)
            } else {
                viewing = record.localIdentifier
            }
        } label: {
            tile(record)
                .selectionOverlay(
                    isSelecting: picking.isActive,
                    isSelected: picking.contains(record.localIdentifier),
                    cornerRadius: 6,
                    tileSide: tileSide
                )
        }
        .buttonStyle(.plain)
        // A photograph draws nothing a screen reader can name, so without this
        // the library is fifteen thousand announcements of the word "Button".
        // The label is built from the row the app already holds, so it says
        // what the picture is and when it was taken — which is how anyone
        // tells one photograph from another.
        .accessibilityLabel(label(for: record))
        // Named so the UI tour can reach a photograph by asking for one. It used to tap
        // `scrollViews.buttons.element(boundBy: 2)` — the third button on the screen, whatever
        // that happened to be — which is how the tour once spent nine steps photographing
        // Settings and reported nothing wrong.
        .accessibilityIdentifier("asset.tile")
        // The overlay's own trait cannot reach out here: traits set inside a
        // button's label do not merge into the button. Stated again on the
        // element VoiceOver actually focuses.
        .accessibilityAddTraits(
            picking.isActive && picking.contains(record.localIdentifier)
                ? [.isSelected] : []
        )
        // The context menu below is the only way to love, hide or share from a
        // grid. A hold does surface it under VoiceOver, but nothing tells the
        // reader a hold does anything — the rotor is where they look, and
        // without these there is nothing in it.
        .accessibilityActions {
            if !picking.isActive { rotorActions(for: record) }
        }
        // Outside the button rather than inside its label. A control nested in
        // a button's label never receives the touch — the button around it
        // swallows every tap — so Restore on the Hidden screen looked like a
        // button and behaved like part of the photograph.
        .overlay(alignment: .topTrailing) {
            if let trailingAction, !picking.isActive {
                trailingAction(record)
            }
        }
        // Tell Photos what is coming before it is asked for. Without this every
        // tile is a cold request issued at the moment it appears.
        .onAppear {
            prefetcher.tileAppeared(at: index,
                                    identifiers: identifiers,
                                    side: tileSide)
        }
        // Holding a tile to reach its menu would fight picking it, so the menu
        // steps aside for as long as selection is running.
        .contextMenu(menuItems: {
            if !picking.isActive { actions(for: record) }
        }, preview: {
            preview(record)
        })
        .matchedTransitionSource(id: record.localIdentifier, in: opening)
    }

    private func tile(_ record: AssetRecord) -> some View {
        PhotoImageView(identifier: record.localIdentifier, targetSide: tileSide)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if record.isVideo || record.isLivePhoto {
                    // Everything the badge says is already in the tile's own label, so as a
                    // second element it would only add a focus stop inside one photograph.
                    MediaBadge(record: record)
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                // The heart only. Anything tappable lives outside the button that wraps this,
                // where it can actually be tapped.
                if trailingAction == nil, record.isLoved {
                    Image(systemName: "heart.fill")
                        // Chrome in the corner of a photograph: fixed by the tile's geometry,
                        // so it does not grow with the reader's text size. "Loved" is in the
                        // tile's accessibility label instead.
                        .font(Typo.glyph(11, .regular))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(heartNeedsBacking ? Palette.labelScrim : Color.clear,
                                    in: .circle)
                        // A shadow with no colour is black at a third opacity spread over two
                        // points — the weakest separation in the app, under the smallest white
                        // mark in it. Over a bright photograph the heart simply vanished, and
                        // it is the only thing saying which pictures are loved.
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
    }

    /// A shadow is enough over most photographs. It is not what a reader who has asked for
    /// Increase Contrast or Reduce Transparency is asking for, and the app already owns the
    /// right token for a small white mark on an unknown picture.
    private var heartNeedsBacking: Bool {
        reduceTransparency || contrast == .increased
    }

    // MARK: What a tile is

    /// What VoiceOver says about one photograph.
    ///
    /// Kind first, because it is what decides whether the rest is worth hearing; then how long,
    /// for a clip, since duration is the thing that separates one video from the next in a run
    /// of them; then when it was taken, which is how anyone actually identifies a photograph.
    /// Loved comes last because it is state rather than identity.
    ///
    /// Every part is formatted rather than assembled from numbers, so the digits and the date
    /// order follow the reader's locale instead of this file's.
    private func label(for record: AssetRecord) -> String {
        var parts: [String] = [kindName(record)]

        if record.isVideo, record.duration > 0 {
            parts.append(
                Duration.seconds(Int(record.duration.rounded()))
                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            )
        }

        parts.append(record.momentDate.formatted(date: .abbreviated, time: .shortened))
        if record.isLoved { parts.append("Loved") }
        return parts.joined(separator: ", ")
    }

    private func kindName(_ record: AssetRecord) -> String {
        if record.isVideo { return "Video" }
        if record.isLivePhoto { return "Live Photo" }
        if record.isScreenshot { return "Screenshot" }
        return "Photo"
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

    /// The same four things, in the Actions rotor.
    ///
    /// Deliberately a shorter list than the context menu: the rotor is spoken one item at a
    /// time, so it carries the actions that change something about the photograph and leaves
    /// out "Show Similar Photos", which is a place to go rather than a thing to do and is
    /// reachable by opening the picture.
    @ViewBuilder
    private func rotorActions(for record: AssetRecord) -> some View {
        Button(record.isLoved ? "Remove from loved" : "Love") { toggleLoved(record) }
        Button("Share") { Task { await prepareShare(record) } }
        Button("Save to a collection") { savingFor = record.localIdentifier }
        if !record.excludedFromMemories {
            Button("Hide from Memories") { hide(record) }
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
    /// waits for a full-size load. If the original cannot be fetched — an iCloud asset with no
    /// network — the user is told. Saying nothing was the quieter choice and it was the wrong
    /// one: from the user's side a menu item that opens nothing is indistinguishable from a
    /// menu item that is broken.
    private func prepareShare(_ record: AssetRecord) async {
        guard let image = await PhotoImageLoader.shared.image(
            forIdentifier: record.localIdentifier,
            targetSize: CGSize(width: 2048, height: 2048),
            purpose: .display
        ) else {
            shareFailure = "The original is not on this device. Connect to the internet and try again."
            return
        }
        shareImage = image
    }
}

/// A screen that is just a titled grid of one slice of the library.
struct AssetCollectionScreen: View {
    let title: String
    let records: [AssetRecord]
    var emptyTitle: String = "Nothing here yet"
    var emptyDetail: String?
    var isLoading = false

    /// Owned here rather than inside the grid so the batch bar can be pinned to the screen.
    @State private var selection = PhotoSelection()

    /// What the floating tab bar actually measured. A literal 132 was right on one phone at one
    /// text size and wrong everywhere else — larger type grows the bar, landscape changes the
    /// home-indicator inset, and inside a sheet the bar is not drawn at all.
    @Environment(\.bottomBarInset) private var bottomBarInset

    var body: some View {
        ScrollView {
            AssetGridView(records: records,
                          emptyTitle: emptyTitle,
                          emptyDetail: emptyDetail,
                          isLoading: isLoading,
                          selection: selection)
                .padding(.bottom, bottomBarInset)
        }
        .scrollIndicators(.hidden)
        .selectionActionBar(selection)
        .background(Palette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
