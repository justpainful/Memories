import Observation
import SwiftUI

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
    var title: String {
        switch count {
        case 0:  return "Select Items"
        case 1:  return "1 Photo Selected"
        default: return "\(count) Photos Selected"
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
struct SelectionCheck: View {
    let isSelected: Bool

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
        .font(.system(size: 21, weight: .semibold))
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
    func selectionOverlay(isSelecting: Bool,
                          isSelected: Bool,
                          cornerRadius: CGFloat = Radius.thumb) -> some View {
        modifier(SelectionOverlayModifier(isSelecting: isSelecting,
                                          isSelected: isSelected,
                                          cornerRadius: cornerRadius))
    }
}

private struct SelectionOverlayModifier: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if isSelecting && !isSelected {
                    // Dimming what was left behind is what makes a half-picked grid legible
                    // at a glance. Without it the user has to hunt for small blue marks.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Palette.photoScrim)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    SelectionCheck(isSelected: isSelected).padding(5)
                }
            }
            // Scaling last so the mark and the dimming travel with the tile instead of
            // hanging off its corner.
            .scaleEffect(isSelected ? 0.93 : 1)
            .animation(.smooth(duration: 0.18), value: isSelected)
            .animation(.smooth(duration: 0.18), value: isSelecting)
    }
}

// MARK: - The bar

/// The floating batch-action bar: the same four things the app already does to one photo at
/// a time, done to the whole selection.
///
/// It is a floating control cluster over a grid whose brightness is unpredictable, so it uses
/// the regular material rather than clear — the same reasoning as the tab bar. The count is
/// not repeated here because it belongs in the navigation title (`PhotoSelection.title`).
struct SelectionActionBar: View {
    let selection: PhotoSelection

    @Environment(\.app) private var app
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
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.s)
                    .glassPanel(cornerRadius: 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
        .animation(.smooth(duration: 0.25), value: caption)
        .animation(.smooth(duration: 0.2), value: selection.isEmpty)
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

    private func love() {
        let identifiers = selection.identifiers
        for identifier in identifiers { app.feedback.setLoved(true, identifier: identifier) }
        Haptics.impact(.light)
        finish("Loved \(phrase(identifiers.count))")
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
            confirm("Sharing the first \(Self.shareLimit)")
        }
        shareBatch = ShareBatch(images: images)
    }

    /// A finished batch empties the selection but stays in selection mode, so the user can see
    /// what happened and carry on picking. Sharing is left alone: the set is still wanted once
    /// the share sheet closes.
    private func finish(_ text: String) {
        confirm(text)
        selection.clear()
    }

    private func confirm(_ text: String) {
        confirmation = text
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if confirmation == text { confirmation = nil }
        }
    }

    private func phrase(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
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
