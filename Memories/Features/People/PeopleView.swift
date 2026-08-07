import SwiftData
import SwiftUI
import UIKit

/// The people the app thinks it has found, shown as faces rather than as photographs.
///
/// Nobody is named until the user names them. There is no contacts access and no network, so
/// the app has nowhere to look a name up from and never guesses at one.
struct PeopleView: View {
    @Environment(\.app) private var app
    @Query(sort: \PersonRecord.faceCount, order: .reverse) private var people: [PersonRecord]

    @State private var showsHidden = false
    @State private var renaming: PersonRecord?
    @State private var draftName = ""
    @State private var faceCount = 0
    @State private var isStillLooking = true

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Space.l)]

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
                                PersonTile(person: person)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: person) }
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.m)
                    .padding(.bottom, 132)
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
        .onChange(of: app.coordinator.progress) { _, _ in load() }
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
            draftName = person.name ?? ""
            renaming = person
        } label: {
            Label(person.isNamed ? "Rename" : "Add Name", systemImage: "pencil")
        }

        Button {
            person.isHidden.toggle()
            app.container.mainContext.saveIfNeeded()
            Haptics.impact(.light)
        } label: {
            Label(person.isHidden ? "Show" : "Hide",
                  systemImage: person.isHidden ? "eye" : "eye.slash")
        }
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

    var body: some View {
        VStack(spacing: Space.s) {
            FaceThumbnail(person: person)
                .opacity(person.isHidden ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if person.isHidden {
                        Image(systemName: "eye.slash.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.canvas, Palette.textSecondary)
                    }
                }

            Text(person.displayName)
                .font(Typo.label)
                .foregroundStyle(person.isNamed ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(1)

            Text(count)
                .font(Typo.meta)
                .foregroundStyle(Palette.textTertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(person.displayName), \(count)")
    }

    private var count: String {
        let total = person.assetIdentifiers.count
        return "\(total) \(total == 1 ? "photo" : "photos")"
    }
}

/// Everything one person appears in.
private struct PersonScreen: View {
    let person: PersonRecord

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []

    var body: some View {
        AssetCollectionScreen(
            title: person.displayName,
            records: records,
            emptyTitle: "Nothing left here",
            emptyDetail: "The photographs they appeared in are no longer in your library."
        )
        .task {
            records = LibraryQuery.records(for: person.assetIdentifiers,
                                           context: app.container.mainContext)
        }
    }
}

// MARK: - The face itself

/// A person's face, cut out of the photograph it was found in.
///
/// Showing the whole frame would defeat the screen: at 104 points a face inside a landscape is
/// a few pixels across, and the point of a grid of people is recognising somebody at a glance.
private struct FaceThumbnail: View {
    let person: PersonRecord
    var side: CGFloat = 104

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
                Image(systemName: "person.fill")
                    .font(.system(size: side * 0.34, weight: .light))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 0.5) }
        .animation(.easeOut(duration: 0.22), value: image != nil)
        .task(id: person.coverAssetIdentifier) { await load() }
    }

    private func load() async {
        guard let identifier = person.coverAssetIdentifier else { return }

        // The face is a fraction of the frame, so the frame has to be fetched several times
        // larger than the tile or the crop comes back soft.
        let requested = side * UIScreen.main.scale * 3
        guard let full = await PhotoImageLoader.shared.image(
            forIdentifier: identifier,
            targetSize: CGSize(width: requested, height: requested),
            purpose: .browsing
        ) else { return }

        let box = CGRect(x: person.coverBoundingX,
                         y: person.coverBoundingY,
                         width: person.coverBoundingWidth,
                         height: person.coverBoundingHeight)
        image = FaceCrop.square(from: full, box: box, side: side * UIScreen.main.scale)
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
