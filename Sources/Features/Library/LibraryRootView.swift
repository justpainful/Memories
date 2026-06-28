import SwiftUI

enum LibrarySegment: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case saved = "Saved"

    var id: String { rawValue }
}

struct LibraryRootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var segment: LibrarySegment = .all

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView(theme: appModel.appTheme)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerCard
                            .accessibilityIdentifier("library.header")

                        filterRow

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(items) { candidate in
                                Button {
                                    appModel.openCandidate(candidate)
                                } label: {
                                    MemoryLibraryTile(candidate: candidate, theme: appModel.appTheme)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        shareStatusCard
                            .accessibilityIdentifier("library.shareStatus")
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Library")
        }
    }

    private var headerCard: some View {
        AppGlassCard(theme: appModel.appTheme) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Private library")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appModel.appTheme.primaryText)
                Text("Browse everything locally, filter by media kind, and keep saved memories close without duplicating the originals.")
                    .foregroundStyle(appModel.appTheme.secondaryText)
            }
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(LibrarySegment.allCases) { option in
                    Button(option.rawValue) {
                        segment = option
                    }
                    .buttonStyle(option == segment ? .glassProminent : .glass)
                    .accessibilityIdentifier("library.filter.\(option.rawValue.lowercased())")
                }
            }
        }
    }

    private var shareStatusCard: some View {
        AppGlassCard(theme: appModel.appTheme) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Temporary share exports")
                    .font(.headline)
                    .foregroundStyle(appModel.appTheme.primaryText)
                Text("Exports are created only when you share a memory and are stored in a temporary directory for cleanup.")
                    .foregroundStyle(appModel.appTheme.secondaryText)
            }
        }
    }

    private var items: [MemoryCandidate] {
        switch segment {
        case .all: appModel.libraryAll
        case .photos: appModel.libraryPhotos
        case .videos: appModel.libraryVideos
        case .saved: appModel.librarySaved
        }
    }
}

private struct MemoryLibraryTile: View {
    let candidate: MemoryCandidate
    let theme: AppTheme

    var body: some View {
        AppGlassCard(theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accent.opacity(0.6), theme.secondaryAccent.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 180)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                Text(candidate.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable")
                    .font(.headline)
                    .foregroundStyle(theme.primaryText)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var symbol: String {
        switch candidate.mediaKind {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "livephoto"
        }
    }

    private var statusText: String {
        switch candidate.status {
        case .eligible: "Available in Memories"
        case .saved: "Saved locally"
        case .blocked: "Blocked"
        case .missing: "Unavailable"
        }
    }
}
