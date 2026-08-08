import SwiftData
import SwiftUI

/// Not a marketing page.
///
/// Every figure here is read from the app's own state, and the zeroes are zero because there
/// is no networking code in this project to make them anything else.
struct PrivacyView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var processed = 0
    @State private var withFeatures = 0

    var body: some View {
        List {
            // The counts are figures, so they are formatted as figures: interpolating an `Int`
            // straight into a string prints it with no grouping separator and in no particular
            // numbering system, beside dates on the same screen that are localized properly.
            Section("Photos") {
                LabeledContent("Access", value: app.library.access.title)
                LabeledContent("Read on \(DeviceName.thisDevice)", value: processed.formatted(.number))
                LabeledContent("Examined for detail", value: withFeatures.formatted(.number))
            }

            Section {
                LabeledContent("Photos uploaded", value: 0.formatted(.number))
                // "External AI services" and "Analyzed with Vision" were the two lines on this
                // screen written for a developer rather than for a reader: one is jargon the
                // app avoids everywhere else, and the other is the name of a framework, which
                // Apple never puts in front of a user. The counts and the promise are the same;
                // they are simply said in words that describe what happened.
                LabeledContent("External services", value: "None")
                LabeledContent("External analytics", value: "None")
                LabeledContent("Accounts", value: "None")
            } header: {
                Text("Leaving this device")
            } footer: {
                Text("Memories has no backend and no sign-in. Photographs are examined here, on \(DeviceName.thisDevice), and what is worked out about them stays here too.")
            }

            Section {
                // "Apple geocoder" was the name of the thing rather than what happens; the
                // footer under it already explains the exchange in full.
                LabeledContent("Place names", value: "Looked up by Apple")
            } header: {
                Text("The one exception")
            } footer: {
                // This paragraph had to change when place naming moved out of the details panel
                // and into indexing. It used to say the lookup happened when you opened a
                // photo's details, which was true then and became false the moment the app
                // started naming every located occasion on its own. A privacy page that
                // describes an older version of the app is worse than no privacy page: it is
                // the one screen a reader is entitled to take literally.
                Text("Coordinates your camera saved are sent to Apple’s geocoding service to be turned into a place name — while your library is being read through, and when you open the details of a photo that has not been named yet. Coordinates only: no photograph, and nothing that identifies you or this device. Everything else happens offline.")
            }

            Section {
                LabeledContent("Photos copied by Memories", value: 0.formatted(.number))
            } header: {
                Text("Your library")
            } footer: {
                // This screen is the app's promise in writing, so it names the one thing that
                // does get written rather than rounding it down to "nothing". The heart is a
                // deliberate exception: it is Photos' own favourite flag, and a heart that
                // disagreed with the one in Photos would be worse than no heart at all.
                Text("Memories stores identifiers and computed details, never a second copy of your photos. Hiding a photo from Memories does not delete it. The only change Memories makes to your library is the heart: loving a photo here favourites it in Photos, exactly as if you had tapped it there.")
            }
        }
        .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
        // Prose, so it stops at a readable measure rather than running the width of an iPad.
        .readableMeasure()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    /// Two numbers, so two counts. Assembling them from rows would materialise the whole
    /// library — including every feature print — to print a pair of integers.
    private func load() {
        let context = app.container.mainContext
        processed = (try? context.fetchCount(FetchDescriptor<AssetRecord>())) ?? 0
        withFeatures = (try? context.fetchCount(
            FetchDescriptor<AssetRecord>(predicate: #Predicate { $0.featurePrint != nil })
        )) ?? 0
    }
}

/// What the app is using on disk, and the one button that gives it back.
struct StorageView: View {
    @Environment(\.app) private var app
    @Environment(\.bottomBarInset) private var bottomBarInset
    @State private var databaseBytes: Int64 = 0
    @State private var analysisBytes: Int64 = 0
    @State private var recordCount = 0
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                LabeledContent("Database", value: format(databaseBytes))
                LabeledContent("Analysis Cache", value: format(analysisBytes))
                LabeledContent("Thumbnails", value: "Managed by Photos")
                // The store is the only thing Memories writes, so the total is that file
                // rather than the sum of the lines above it.
                LabeledContent("Total", value: format(databaseBytes))
            } footer: {
                Text("The analysis cache is what Memories worked out about how each photograph looks. It is kept inside the database rather than beside it, so it is part of that figure and not added to it. Thumbnails belong to Photos and are never copied here, which is why Memories stays small even for very large libraries.")
            }

            Section {
                LabeledContent("Rows", value: recordCount.formatted(.number))
            } footer: {
                Text("One row for each item in your library: identifiers and computed details, never a second copy of the photo.")
            }

            Section {
                Button("Clear Analysis Cache", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Removes feature prints, quality scores, occasions and generated memories. Your photos are untouched, and everything is recomputed as it is needed.")
            }
        }
        .contentMargins(.bottom, bottomBarInset, for: .scrollContent)
        .readableMeasure()
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear analysis cache?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task {
                    await app.coordinator.clearAnalysisCache()
                    load()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { load() }
    }

    private func load() {
        let context = app.container.mainContext
        recordCount = (try? context.fetchCount(FetchDescriptor<AssetRecord>())) ?? 0
        databaseBytes = Self.storeSize()

        let container = app.container
        Task { @MainActor in
            analysisBytes = await AnalysisCacheSize(modelContainer: container).totalBytes()
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// SwiftData writes a SQLite store plus its journal files into Application Support.
    private static func storeSize() -> Int64 {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let contents = try? manager.contentsOfDirectory(at: base,
                                                              includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("default.store") }
            .reduce(Int64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + Int64(size)
            }
    }
}

/// Feature prints are the only derived data large enough to be worth a line of its own. The
/// scores and group assignments beside them are a handful of numbers per row, and they sit in
/// the same store file, so they are already counted in the database figure.
///
/// This is the one figure on the screen that cannot be asked for: SwiftData offers no way to
/// have SQLite sum the length of a blob column, so an honest total means reading every print
/// back — tens of megabytes on a large library, to produce one line of text. It is at least
/// paid on a background context, narrowed to the rows that have a print, and only the total
/// crosses back to the screen.
@ModelActor
private actor AnalysisCacheSize {
    func totalBytes() -> Int64 {
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.featurePrint != nil }
        )
        guard let records = try? modelContext.fetch(descriptor) else { return 0 }
        return records.reduce(Int64(0)) { $0 + Int64($1.featurePrint?.count ?? 0) }
    }
}
