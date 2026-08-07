import SwiftData
import SwiftUI

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

    @State private var viewing: String?
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 4)]

    var body: some View {
        Group {
            if records.isEmpty {
                QuietStatusView(title: emptyTitle, detail: emptyDetail, symbol: emptySymbol)
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(records, id: \.localIdentifier) { record in
                        Button { viewing = record.localIdentifier } label: {
                            tile(record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewing.map(ViewerRequest.init(identifier:)) },
            set: { viewing = $0?.identifier }
        )) { request in
            PhotoViewerView(identifiers: records.map(\.localIdentifier), startAt: request.identifier)
        }
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
