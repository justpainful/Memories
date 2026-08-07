import Observation
import SwiftData
import SwiftUI
import UIKit

/// Multi-select for the grids, the way Photos does it.
///
/// Meant to be adopted by `AssetGridView` in `Memories/Features/Library/AssetGridView.swift`,
/// which every "show me these photos" screen already goes through — the library, a
/// collection, search results, Best Of, Hidden. The host does four things:
///
/// 1. Owns a `PhotoSelection` as `@State` and puts a Select button in its toolbar that calls
///    `begin()` / `end()`.
/// 2. Uses `selection.title` as the navigation title while `isActive`.
/// 3. Applies `.selectionOverlay(isSelecting:isSelected:)` to each tile, and sends a tap to
///    `toggle(_:)` instead of opening the viewer while selecting.
/// 4. Overlays `SelectionActionBar(selection:)` at the bottom while `isActive`.
///
/// The three pieces are deliberately independent: a screen can take the model without the
/// bar, or draw the overlay on a tile shape that is not the standard one.

// MARK: - The model

/// What is currently picked, and whether the grid is picking at all.
@MainActor
@Observable
final class PhotoSelection {
    /// Selection mode itself. Tapping a tile opens the viewer when this is off, and toggles
    /// the tile when it is on.
    private(set) var isActive = false

    /// Kept in the order the user tapped rather than as a bare set, so "Save to a collection"
    /// keeps that order and the first tap is the one that becomes the collection's cover.
    private(set) var identifiers: [String] = []

    /// Membership is asked for once per tile per layout pass, so it cannot be a linear search
    /// through the array.
    private var chosen: Set<String> = []

    var count: Int { identifiers.count }
    var isEmpty: Bool { identifiers.isEmpty }

    /// The navigation title while selecting: the instruction until something is picked, then
    /// the count, which is where Photos puts it.
    ///
    /// The number goes through `formatted()` rather than straight interpolation. Bare
    /// interpolation emits ASCII digits with no grouping, so a large library reads "1247"
    /// beside dates that are being rendered with the reader's own numbering system — the same
    /// screen mixing two conventions.
    var title: String {
        switch count {
        case 0:  return "Select Items"
        case 1:  return "1 Photo Selected"
        default: return "\(count.formatted()) Photos Selected"
        }
    }

    func contains(_ identifier: String) -> Bool { chosen.contains(identifier) }

    func begin() {
        guard !isActive else { return }
        isActive = true
        Haptics.selection()
    }

    /// Leaving selection mode always drops what was picked. A grid that quietly remembers ten
    /// photos while looking idle is how a batch action ends up applied to the wrong set.
    func end() {
        isActive = false
        clear()
    }

    func select(_ identifier: String) {
        guard chosen.insert(identifier).inserted else { return }
        identifiers.append(identifier)
    }

    func deselect(_ identifier: String) {
        guard chosen.remove(identifier) != nil else { return }
        identifiers.removeAll { $0 == identifier }
    }

    func toggle(_ identifier: String) {
        if contains(identifier) {
            deselect(identifier)
        } else {
            select(identifier)
        }
        Haptics.selection()
    }

    /// Adds everything on screen without disturbing what was already picked or its order.
    func selectAll(_ all: [String]) {
        for identifier in all { select(identifier) }
        Haptics.impact(.light)
    }

    func clear() {
        identifiers.removeAll()
        chosen.removeAll()
    }
}

// MARK: - The mark on a tile

/// The check Photos draws in the corner of a tile.
///
/// Two shapes, not two colours: a filled tick for picked and an empty ring for not. That is
/// deliberate and it is what makes selection survive Differentiate Without Color and a
/// greyscale rendering — the state is carried by the outline, and the accent is only there
/// because Photos puts it there.
struct SelectionCheck: View {
    let isSelected: Bool
    /// How big the mark is drawn. The caller knows the tile; the mark does not.
    var side: CGFloat = 21

    var body: some View {
        Group {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Palette.accent)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
        // `Typo.glyph`, so the mark does not grow with the reader's text size. It sits in the
        // corner of a photograph that cannot grow with it — at seven across the tile is about
        // fifty points, and a tick scaled to accessibility sizes would be wider than the
        // picture it is marking and would hang over its neighbour. What the mark means is
        // carried by the `.isSelected` trait below, which is where a reader who needs larger
        // type is actually being served.
        .font(Typo.glyph(side))
        // What is behind the mark is a photograph of unknown brightness, so it carries its
        // own separation rather than trusting the image to provide any.
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

extension View {
    /// Turns a grid tile into a selectable one: the mark, the dimming, and the small shrink
    /// that makes a chosen tile read as picked up rather than merely ticked.
    ///
    /// `cornerRadius` should match the tile's own clip shape so the dimming lands on it
    /// exactly; `AssetGridView` clips its tiles at 6.
    ///
    /// `tileSide` is how wide the tile is being drawn right now, and it is optional because a
    /// caller that has not measured itself is better served by the default mark than by a
    /// guess. When it is given, the mark is sized from it, so the tick stays a corner badge at
    /// two photographs across and at seven.
    func selectionOverlay(isSelecting: Bool,
                          isSelected: Bool,
                          cornerRadius: CGFloat = Radius.thumb,
                          tileSide: CGFloat = 0) -> some View {
        modifier(SelectionOverlayModifier(isSelecting: isSelecting,
                                          isSelected: isSelected,
                                          cornerRadius: cornerRadius,
                                          markSide: tileSide > 0
                                              ? min(21, max(13, tileSide * 0.34))
                                              : 21))
    }
}

private struct SelectionOverlayModifier: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat
    let markSide: CGFloat

    /// The shrink is the one part of this that moves, and it fires once per tap in a mode
    /// whose whole purpose is tapping many tiles in a row.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The dimming is a fixed wash over photography, which is exactly what both of these
    /// settings are asking to be told about.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .overlay {
                if isSelecting && !isSelected {
                    // Dimming what was left behind is what makes a half-picked grid legible
                    // at a glance. Without it the user has to hunt for small blue marks.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(dimming)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    SelectionCheck(isSelected: isSelected, side: markSide)
                        .padding(5)
                        // Unlabelled it would be read aloud as "checkmark circle fill", and on
                        // a tile that is a single element it would be the *whole*
                        // announcement. The `.isSelected` trait below says the same thing in
                        // the words VoiceOver already uses for it.
                        .accessibilityHidden(true)
                }
            }
            // Scaling last so the mark and the dimming travel with the tile instead of
            // hanging off its corner.
            .scaleEffect(reduceMotion ? 1 : (isSelected ? 0.93 : 1))
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSelected)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSelecting)
            // Without this a picked tile and an unpicked one are the same announcement, and a
            // reader who cannot see the tick has no way to check what a batch is about to be
            // applied to.
            .accessibilityAddTraits(isSelecting && isSelected ? [.isSelected] : [])
    }

    /// A wash over a photograph, at the weight the reader asked for.
    ///
    /// The default is tuned to veil the frame without hiding it. Reduce Transparency and
    /// Increase Contrast are both requests for a firmer separation than that, and the
    /// separation here is the only thing saying "this one was left behind".
    private var dimming: Color {
        reduceTransparency || contrast == .increased
            ? Color.black.opacity(0.62)
            : Palette.photoScrim
    }
}

// MARK: - The bar

extension View {
    /// Pins the batch bar above the app's floating tab bar. Applied to a **scroll view**, never
    /// to the content inside one.
    ///
    /// That distinction is the whole reason this exists. `safeAreaInset` lays its content beside
    /// the view it modifies, so attached to the grid — which is the scrolled content — the bar
    /// came out at the *end of the photographs* rather than at the bottom of the screen. On a
    /// short grid nobody noticed; on fifteen thousand items it meant picking four photos and
    /// then scrolling to the end of the library to find the buttons. Attached to the scroll view
    /// the same modifier pins the bar to the viewport and insets the content behind it, which is
    /// what it was always meant to do here.
    ///
    /// A `ViewModifier` rather than a chain written inline, because it has to read the
    /// environment — the bar's measured height and Reduce Motion — and a `View` extension has
    /// no environment of its own to read.
    @MainActor
    func selectionActionBar(_ selection: PhotoSelection) -> some View {
        modifier(SelectionActionBarModifier(selection: selection))
    }
}

private struct SelectionActionBarModifier: ViewModifier {
    let selection: PhotoSelection

    /// A bar translating in from off the bottom edge is directional motion, which is the class
    /// of animation Reduce Motion exists to turn into a cross-dissolve.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the floating tab bar actually measured, rather than the 132 this used to write —
    /// a number taken once, on one phone, at the default text size.
    @Environment(\.bottomBarInset) private var bottomBarInset

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if selection.isActive {
                    SelectionActionBar(selection: selection)
                        // Clears the glass tab bar, which is drawn by the app rather than by
                        // the system and so insets nothing on its own.
                        .padding(.bottom, bottomBarInset)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: selection.isActive)
    }
}

/// The floating batch-action bar: the same four things the app already does to one photo at
/// a time, done to the whole selection.
///
/// It is a floating control cluster over a grid whose brightness is unpredictable, so it uses
/// the regular material rather than clear — the same reasoning as the tab bar. The count is
/// not repeated here because it belongs in the navigation title (`PhotoSelection.title`).
struct SelectionActionBar: View {
    let selection: PhotoSelection

    @Environment(\.app) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSaving = false
    @State private var shareBatch: ShareBatch?
    @State private var isPreparingShare = false
    @State private var confirmation: String?

    /// Full-quality originals may have to come down from iCloud one at a time, so a large
    /// selection is capped and the user is told, rather than left holding a frozen bar.
    private static let shareLimit = 12

    var body: some View {
        VStack(spacing: Space.s) {
            if let caption {
                Text(caption)
                    .font(Typo.control)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    // The caption carries a library's refusal as well as a confirmation, and
                    // those sentences are long. Two lines that shrink a little is a caption;
                    // one line that clips is a bug report.
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.s)
                    .frame(maxWidth: 420)
                    .glassPanel(cornerRadius: 18)
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.95)))
            }

            GlassEffectContainer(spacing: 18) {
                HStack(spacing: 14) {
                    GlassIconButton(systemImage: "heart", label: "Love selected") { love() }

                    GlassIconButton(systemImage: "plus.rectangle.on.folder",
                                    label: "Save selected to a collection") { isSaving = true }

                    GlassIconButton(systemImage: "square.and.arrow.up",
                                    label: "Share selected") { Task { await share() } }

                    GlassIconButton(systemImage: "eye.slash",
                                    label: "Hide selected from Memories") { hide() }
                }
            }
            .disabled(selection.isEmpty || isPreparingShare)
            .opacity(selection.isEmpty ? 0.55 : 1)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: caption)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: selection.isEmpty)
        .sheet(isPresented: $isSaving) {
            AddToCollectionSheet(
                items: selection.identifiers.map { CollectionItem(kind: .asset, reference: $0) },
                suggestedCover: selection.identifiers.first
            ) { name in
                finish("Kept \(phrase(selection.count)) in \(name)")
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareBatch) { batch in
            ShareSheet(items: batch.images)
        }
    }

    // MARK: Actions

    private var caption: String? {
        isPreparingShare ? "Preparing photos…" : confirmation
    }

    /// The same heart the viewer draws, so it makes the same promise: this is Photos' own
    /// favourite flag, not a private one. The whole selection goes to the library in a single
    /// change request, and if the library refuses it the rows are put back rather than left
    /// claiming something that never happened.
    private func love() {
        let identifiers = selection.identifiers
        setLoved(true, identifiers: identifiers)
        Haptics.impact(.light)
        finish("Loved \(phrase(identifiers.count))")

        Task {
            guard let failure = await Loved.write(true, identifiers: identifiers) else { return }
            setLoved(false, identifiers: identifiers)
            confirm(failure.message)
        }
    }

    /// Both local flags at once, for the same reason the viewer writes both: the ranking
    /// learns from `isLoved`, and `isFavoriteInPhotos` is what the details panel and the Loved
    /// filter read, so it cannot be left waiting for the next indexing pass.
    private func setLoved(_ loved: Bool, identifiers: [String]) {
        let context = app.container.mainContext
        for identifier in identifiers {
            app.feedback.setLoved(loved, identifier: identifier)
        }
        for record in LibraryQuery.records(for: identifiers, context: context) {
            record.isFavoriteInPhotos = loved
        }
        context.saveIfNeeded()
    }

    /// Hidden from Memories, not deleted. Every photo stays exactly where it is in Photos and
    /// can be brought back from the Hidden Memories screen.
    private func hide() {
        let identifiers = selection.identifiers
        for identifier in identifiers {
            app.feedback.setHiddenFromMemories(true, identifier: identifier)
        }
        Haptics.impact()
        finish("Hidden \(phrase(identifiers.count)) from Memories")
    }

    private func share() async {
        let identifiers = Array(selection.identifiers.prefix(Self.shareLimit))
        guard !identifiers.isEmpty else { return }

        isPreparingShare = true
        var images: [UIImage] = []
        for identifier in identifiers {
            if let image = await PhotoImageLoader.shared.image(
                forIdentifier: identifier,
                targetSize: CGSize(width: 2048, height: 2048),
                purpose: .display
            ) {
                images.append(image)
            }
        }
        isPreparingShare = false

        guard !images.isEmpty else {
            confirm("Could not load these photos")
            return
        }
        if selection.count > Self.shareLimit {
            confirm("Sharing the first \(Self.shareLimit.formatted())")
        }
        shareBatch = ShareBatch(images: images)
    }

    /// A finished batch empties the selection but stays in selection mode, so the user can see
    /// what happened and carry on picking. Sharing is left alone: the set is still wanted once
    /// the share sheet closes.
    ///
    /// The selection is emptied *before* the confirmation goes out, so the one announcement
    /// carries both halves of what just happened: what was done, and that the grid is no
    /// longer holding anything. Two separate announcements would not — posting a second one
    /// immediately after the first replaces it.
    private func finish(_ text: String) {
        selection.clear()
        confirm(text, alsoSaying: "Nothing selected")
    }

    /// The transient caption, and the only evidence a batch ever ran.
    ///
    /// It is drawn for a second and a half and then it is gone, which is fine for a reader who
    /// was looking at it. For one who was not, it never existed: `finish` empties the selection
    /// at the same moment, so a forty-photo hide would otherwise be silence followed by an
    /// empty grid. So the text is posted as an announcement as well as drawn, and when VoiceOver
    /// is speaking it the caption waits long enough to still be on screen when the sentence ends.
    private func confirm(_ text: String, alsoSaying extra: String? = nil) {
        confirmation = text

        let spoken = extra.map { "\(text). \($0)" } ?? text
        AccessibilityNotification.Announcement(spoken).post()

        let linger: Duration = UIAccessibility.isVoiceOverRunning
            ? .seconds(5.0)
            : .seconds(1.6)
        Task {
            try? await Task.sleep(for: linger)
            if confirmation == text { confirmation = nil }
        }
    }

    private func phrase(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted()) photos"
    }
}

/// `ShareSheet` is presented by item, and several images are not identifiable on their own.
struct ShareBatch: Identifiable {
    let id = UUID()
    let images: [UIImage]
}

// MARK: - Preview

private struct SelectionModePreview: View {
    @State private var selection = PhotoSelection()
    private let identifiers = (0..<12).map { "preview-\($0)" }
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(identifiers, id: \.self) { identifier in
                            Button {
                                selection.toggle(identifier)
                            } label: {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Palette.surfaceSunk)
                                    .aspectRatio(1, contentMode: .fit)
                                    .selectionOverlay(isSelecting: selection.isActive,
                                                      isSelected: selection.contains(identifier),
                                                      cornerRadius: 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Space.xs)
                }

                if selection.isActive {
                    SelectionActionBar(selection: selection)
                        .padding(.bottom, Space.gutter)
                }
            }
            .background(Palette.canvas)
            .navigationTitle(selection.isActive ? selection.title : "Library")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            selection.begin()
            selection.select(identifiers[1])
            selection.select(identifiers[4])
        }
    }
}

#Preview {
    SelectionModePreview()
}
