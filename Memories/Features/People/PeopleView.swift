import SwiftData
import SwiftUI
import UIKit

/// The people the app thinks it has found, shown as faces rather than as photographs.
///
/// Nobody is named until the user names them. There is no contacts access and no network, so
/// the app has nowhere to look a name up from and never guesses at one.
struct PeopleView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    @Query(sort: \PersonRecord.faceCount, order: .reverse) private var people: [PersonRecord]

    @State private var showsHidden = false
    @State private var renaming: PersonRecord?
    @State private var draftName = ""
    @State private var faceCount = 0
    @State private var isStillLooking = true

    /// The cell grows with the reader's type instead of the grid packing more of them in.
    ///
    /// A hundred and four points is the width of a face plus the name under it at the default
    /// size. When the name triples and the cell does not, the grid stops being a wall of people
    /// and becomes a wall of "Ale…", "Chr…", "Gra…" — which is the one thing this screen exists
    /// to prevent. Tying the minimum to the name's own text style keeps the two in step.
    @ScaledMetric(relativeTo: .subheadline) private var tileSide: CGFloat = 104

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSide), spacing: Space.l)]
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Space.gutter) {
                        ForEach(visible) { person in
                            NavigationLink {
                                PersonScreen(person: person)
                            } label: {
                                PersonTile(person: person, side: tileSide)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: person) }
                            // The context menu is the only route to renaming and hiding, and a
                            // long press is not a route VoiceOver has. These put the same two
                            // things in the actions rotor, where they are reachable.
                            .accessibilityAction(named: person.isNamed ? "Rename" : "Add Name") {
                                beginRename(person)
                            }
                            .accessibilityAction(named: person.isHidden ? "Show" : "Hide") {
                                setHidden(!person.isHidden, for: person)
                            }
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.m)
                    .padding(.bottom, bottomBarInset)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Palette.canvas)
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hiddenCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsHidden.toggle()
                        Haptics.selection()
                        // The grid silently gains or loses people. Sighted users see that
                        // happen; without this nobody else is told it did.
                        AccessibilityNotification
                            .Announcement(showsHidden ? "Showing hidden people"
                                                      : "Hidden people hidden")
                            .post()
                    } label: {
                        Image(systemName: showsHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showsHidden ? "Hide hidden people" : "Show hidden people")
                }
            }
        }
        .alert(renaming?.isNamed == true ? "Rename" : "Add a name", isPresented: isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { cancelRename() }
        }
        .task { load() }
        // Keyed to the stage, not to progress. Progress ticks continuously through a pass and
        // each tick was re-running two fetches while this screen sat open — hundreds of them,
        // to redraw a list that only actually changes when the people stage finishes.
        .onChange(of: app.coordinator.stage) { _, _ in load() }
        .onChange(of: app.coordinator.isRunning) { _, _ in load() }
    }

    // MARK: Ordering

    /// Named people first, then whoever turns up most.
    ///
    /// Naming somebody is the strongest signal available that they matter, and it is the only
    /// one the user gave deliberately, so it outranks a tally the app worked out on its own.
    private var visible: [PersonRecord] {
        people
            .filter { showsHidden || !$0.isHidden }
            .sorted { lhs, rhs in
                if lhs.isNamed != rhs.isNamed { return lhs.isNamed }
                if lhs.assetIdentifiers.count != rhs.assetIdentifiers.count {
                    return lhs.assetIdentifiers.count > rhs.assetIdentifiers.count
                }
                return lhs.displayName < rhs.displayName
            }
    }

    private var hiddenCount: Int { people.filter(\.isHidden).count }

    // MARK: Empty states

    /// Three different silences, and they mean three different things. Saying "no people" while
    /// the library has not been read yet would be the app blaming an empty screen on the user.
    @ViewBuilder
    private var emptyState: some View {
        if !people.isEmpty {
            QuietStatusView(
                title: "Everyone is hidden",
                detail: "Use the eye in the corner to bring them back.",
                symbol: "eye.slash"
            )
        } else if isStillLooking {
            QuietStatusView(
                title: "Still looking through your photos",
                detail: "People appear once the app has been over your library once. It will not be quick the first time.",
                symbol: "hourglass"
            )
        } else if faceCount > 0 {
            QuietStatusView(
                title: "Nobody turned up twice",
                detail: "Faces were found, but none of them appeared in enough photographs to be worth grouping.",
                symbol: "person.crop.circle.badge.questionmark"
            )
        } else {
            QuietStatusView(
                title: "No faces in this library",
                detail: "Nothing here has a face large or clear enough to group.",
                symbol: "person.crop.circle.badge.xmark"
            )
        }
    }

    private func load() {
        let context = app.container.mainContext
        faceCount = (try? context.fetchCount(FetchDescriptor<FaceRecord>())) ?? 0

        // Faces come out of the same pass that judges quality, so that pass finishing is the
        // moment "we have not looked yet" stops being the honest answer.
        let progress = context.analysisState.stageProgress[AnalysisStage.quality.rawValue] ?? 0
        isStillLooking = app.coordinator.isRunning || progress < 1
    }

    // MARK: Naming and hiding

    @ViewBuilder
    private func menu(for person: PersonRecord) -> some View {
        Button {
            beginRename(person)
        } label: {
            Label(person.isNamed ? "Rename" : "Add Name", systemImage: "pencil")
        }

        Button {
            setHidden(!person.isHidden, for: person)
        } label: {
            Label(person.isHidden ? "Show" : "Hide",
                  systemImage: person.isHidden ? "eye" : "eye.slash")
        }
    }

    private func beginRename(_ person: PersonRecord) {
        draftName = person.name ?? ""
        renaming = person
    }

    /// Hiding somebody has to reach the photographs, not just the tile.
    ///
    /// This used to write `person.isHidden` and save, and nothing anywhere read the flag back —
    /// so the one thing the control promises, that the person stops turning up in memories,
    /// was the one thing it did not do. `PersonVisibility` owns the whole story: it sets the
    /// flag and then brings every asset's `hiddenByPerson` back in line with who is hidden now,
    /// which is what curation actually filters on. A full reconcile rather than a diff, because
    /// a photograph can hold two people and hiding one of them must not take the other's
    /// photographs with it.
    private func setHidden(_ hidden: Bool, for person: PersonRecord) {
        PersonVisibility.setHidden(hidden, person: person, context: app.container.mainContext)
        Haptics.impact(.light)
        AccessibilityNotification
            .Announcement(hidden ? "\(person.displayName) hidden from memories"
                                 : "\(person.displayName) shown in memories")
            .post()
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { cancelRename() } })
    }

    private func commitRename() {
        guard let person = renaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty field means "I would rather not name them", not "call them nothing".
        person.name = name.isEmpty ? nil : name
        app.container.mainContext.saveIfNeeded()
        Haptics.impact(.light)
        // The alert closes and one caption in a grid of faces changes. That is invisible to a
        // reader who is not looking at that one tile.
        AccessibilityNotification
            .Announcement(name.isEmpty ? "Name removed" : "Named \(name)")
            .post()
        cancelRename()
    }

    private func cancelRename() {
        renaming = nil
        draftName = ""
    }
}

// MARK: - One person

private struct PersonTile: View {
    let person: PersonRecord
    var side: CGFloat = 104

    var body: some View {
        VStack(spacing: Space.s) {
            FaceThumbnail(person: person, side: side)
                // Dimming is the colour half of "hidden" and the badge is the shape half, so
                // the state survives greyscale, a colour vision deficiency and Differentiate
                // Without Color without needing to read either of them.
                .opacity(person.isHidden ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if person.isHidden {
                        Image(systemName: "eye.slash.circle.fill")
                            // Sized by the face it is pinned to the corner of, not by the
                            // reader's type: a badge that grows past its thumbnail lands on
                            // the neighbouring one.
                            .font(Typo.glyph(20, .regular))
                            .foregroundStyle(Palette.canvas, Palette.textSecondary)
                    }
                }

            // Two lines and a floor on the scale, because these are names people chose and
            // "Grandma Josephine" truncated to "Gra…" beside three other "Gra…"s is a grid of
            // faces with the one thing that tells them apart taken off it. The row simply
            // grows — a lazy grid has no reason not to let it.
            Text(person.displayName)
                .font(Typo.label)
                .foregroundStyle(person.isNamed ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)

            Text(count)
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// Everything the tile says visually, in one line.
    ///
    /// The badge and the dimming were the only signals that somebody is hidden, and an explicit
    /// label overrides whatever `children: .combine` would have picked up from them — so with
    /// "Show hidden people" on, a VoiceOver user could not tell which people were hidden, and
    /// therefore could not tell what the Show/Hide action was about to do. "Unnamed" is spelled
    /// out for the same reason: on screen it is a grey caption rather than a name, and read
    /// aloud on its own it sounds like one.
    private var spokenLabel: String {
        var parts = [person.isNamed ? person.displayName : "Unnamed person", count]
        if person.isHidden { parts.append("hidden from memories") }
        return parts.joined(separator: ", ")
    }

    private var count: String {
        let total = person.assetIdentifiers.count
        return "\(total.formatted()) \(total == 1 ? "photo" : "photos")"
    }
}

/// Everything one person appears in.
///
/// Not private to this file, and neither is the face below: a memory lists the people in it,
/// and a face that cannot be pressed to see the rest of them is a picture pretending to be a
/// control.
struct PersonScreen: View {
    let person: PersonRecord

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []
    @State private var isLoading = true

    var body: some View {
        AssetCollectionScreen(
            title: person.displayName,
            records: records,
            emptyTitle: "Nothing left here",
            emptyDetail: "The photographs they appeared in are no longer in your library.",
            isLoading: isLoading
        )
        .task {
            records = LibraryQuery.records(for: person.assetIdentifiers,
                                           context: app.container.mainContext)
            isLoading = false
        }
    }
}

// MARK: - The face itself

/// A person's face, cut out of the photograph it was found in.
///
/// Showing the whole frame would defeat the screen: at 104 points a face inside a landscape is
/// a few pixels across, and the point of a grid of people is recognising somebody at a glance.
struct FaceThumbnail: View {
    let person: PersonRecord
    var side: CGFloat = 104

    /// The scale of the display this is actually on, rather than `UIScreen.main`'s answer for
    /// one particular screen. A face is a fraction of its frame, so getting this wrong is the
    /// difference between a crisp crop and a soft one.
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Palette.surfaceSunk

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                // The placeholder is a fraction of the circle it is centred in, so it is sized
                // by geometry rather than by the reader's type — at accessibility sizes a
                // scaling glyph would simply be larger than the face it stands in for.
                Image(systemName: "person.fill")
                    .font(Typo.glyph(side * 0.34, .light))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 0.5) }
        // A cross-fade is the mildest thing on this screen, but a grid of faces fades in a
        // couple of dozen of them at once as it scrolls, and that is the case the setting is
        // about. Nil here means the image simply appears.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: image != nil)
        .task(id: person.coverAssetIdentifier) { await load() }
    }

    private func load() async {
        guard let identifier = person.coverAssetIdentifier else { return }

        // The face is a fraction of the frame, so the frame has to be fetched several times
        // larger than the tile or the crop comes back soft.
        let requested = side * displayScale * 3
        guard let full = await PhotoImageLoader.shared.image(
            forIdentifier: identifier,
            targetSize: CGSize(width: requested, height: requested),
            purpose: .browsing
        ) else { return }

        let box = CGRect(x: person.coverBoundingX,
                         y: person.coverBoundingY,
                         width: person.coverBoundingWidth,
                         height: person.coverBoundingHeight)
        image = FaceCrop.square(from: full, box: box, side: side * displayScale)
    }
}

/// Cuts a square face out of a photograph, given Vision's normalised box.
private enum FaceCrop {
    static func square(from image: UIImage, box: CGRect, side: CGFloat) -> UIImage? {
        let width = image.size.width, height = image.size.height
        guard width > 0, height > 0, side > 0 else { return nil }

        // Vision measures from the lower left of the frame; UIKit draws from the upper left.
        let face = CGRect(x: box.minX * width,
                          y: (1 - box.maxY) * height,
                          width: box.width * width,
                          height: box.height * height)

        // The same margin the grouping pass cropped with, so the face on screen is the face
        // the app actually compared — and so a tight box does not cut off hair and jaw.
        let window = max(face.width, face.height) * (1 + 2 * FaceAnalyzer.cropMargin)
        guard window > 0 else { return nil }

        var origin = CGPoint(x: face.midX - window / 2, y: face.midY - window / 2)
        origin.x = min(max(0, origin.x), max(0, width - window))
        origin.y = min(max(0, origin.y), max(0, height - window))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let scale = side / window
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in
                // Drawing the whole image offset rather than cropping its `CGImage`, because
                // `draw(in:)` applies the image's own orientation and a raw crop does not —
                // which is the difference between a face and an ear.
                image.draw(in: CGRect(x: -origin.x * scale,
                                      y: -origin.y * scale,
                                      width: width * scale,
                                      height: height * scale))
            }
    }
}
