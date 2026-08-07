import SwiftData
import SwiftUI

/// One memory, opened. A calm grid of what it contains, with the Smart/Pure switch right
/// where the decision matters.
struct MemoryDetailView: View {
    let candidate: MemoryCandidate

    @Environment(\.app) private var app
    @State private var mode: CurationMode = .smart
    @State private var records: [AssetRecord] = []
    @State private var viewerStart: String?
    @State private var isSaving = false
    @State private var note: String?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header

                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 10) {
                        GlassChip(title: "Smart", systemImage: "wand.and.sparkles",
                                  isSelected: mode == .smart) { setMode(.smart) }
                        GlassChip(title: "Pure", systemImage: "square.stack",
                                  isSelected: mode == .pure) { setMode(.pure) }
                        Spacer()
                    }
                }
                .padding(.horizontal, Space.gutter)

                if records.isEmpty {
                    QuietStatusView(title: "Nothing left in this memory",
                                    detail: "Everything here has been hidden from Memories.",
                                    symbol: "eye.slash")
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(records, id: \.localIdentifier) { record in
                            Button { viewerStart = record.localIdentifier } label: {
                                gridTile(record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                if mode == .smart, hiddenByCuration > 0 {
                    Button {
                        setMode(.pure)
                    } label: {
                        Label("Show all \(candidate.assetCount)", systemImage: "square.stack.3d.down.right")
                            .font(Typo.control)
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.gutter)
                }
            }
            .padding(.top, Space.s)
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle(candidate.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // The save is recorded when the collection is actually chosen, not when
                    // the sheet opens — cancelling is not saving.
                    Button("Save to a collection", systemImage: "plus.rectangle.on.folder") {
                        isSaving = true
                    }
                    Button("Show me fewer like this", systemImage: "hand.thumbsdown") {
                        app.feedback.recordDismissed(candidate)
                        note = "This kind will show up less often"
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewerStart.map(ViewerRequest.init(identifier:)) },
            set: { viewerStart = $0?.identifier }
        )) { request in
            PhotoViewerView(identifiers: records.map(\.localIdentifier),
                            startAt: request.identifier)
        }
        .sheet(isPresented: $isSaving) {
            // A whole memory is kept as a memory, not exploded into loose files, plus its
            // frames so the collection can still be browsed as pictures.
            AddToCollectionSheet(
                items: [CollectionItem(kind: .memory, reference: candidate.id)]
                    + records.map { CollectionItem(kind: .asset, reference: $0.localIdentifier) },
                suggestedCover: candidate.coverIdentifier
            ) { name in
                app.feedback.recordSaved(candidate)
                note = "Kept in \(name)"
            }
            .presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if let note {
                Text(note)
                    .font(Typo.control)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.m)
                    .glassPanel(cornerRadius: 20)
                    .padding(.bottom, 150)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.25), value: note)
        .onChange(of: note) { _, value in
            guard value != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                note = nil
            }
        }
        .task {
            mode = app.settings.smartCuration ? .smart : .pure
            reload()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(candidate.referenceDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .overlineStyle()
            if let subtitle = candidate.subtitle {
                Text(subtitle)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
    }

    private func gridTile(_ record: AssetRecord) -> some View {
        PhotoImageView(identifier: record.localIdentifier, targetSide: 240)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if record.isVideo || record.isLivePhoto {
                    MediaBadge(record: record).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if record.isLoved {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
    }

    private var hiddenByCuration: Int {
        max(0, candidate.assetCount - records.count)
    }

    private func setMode(_ newMode: CurationMode) {
        guard mode != newMode else { return }
        mode = newMode
        Haptics.selection()
        withAnimation(.smooth(duration: 0.3)) { reload() }
    }

    private func reload() {
        var options = app.settings.curationOptions
        options.mode = mode
        // A memory the user opened deliberately shows what it contains, including
        // screenshots if that is what the occasion was.
        options.includeScreenshots = true

        let all = LibraryQuery.records(for: candidate.assetIdentifiers,
                                       context: app.container.mainContext)
            .filter { LibraryQuery.passes($0, options: options) }
        records = Curator.curate(all, options: options)
    }
}

/// `fullScreenCover(item:)` needs an Identifiable; a bare String is not one.
struct ViewerRequest: Identifiable, Hashable {
    let identifier: String
    var id: String { identifier }
}
