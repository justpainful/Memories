import SwiftData
import SwiftUI

/// Not a marketing page.
///
/// Every figure here is read from the app's own state, and the zeroes are zero because there
/// is no networking code in this project to make them anything else.
struct PrivacyView: View {
    @Environment(\.app) private var app
    @State private var processed = 0
    @State private var withFeatures = 0

    var body: some View {
        List {
            Section("Photos") {
                LabeledContent("Access", value: app.library.access.title)
                LabeledContent("Items processed on this iPhone", value: "\(processed)")
                LabeledContent("Analyzed with Vision", value: "\(withFeatures)")
            }

            Section {
                LabeledContent("Photos uploaded", value: "0")
                LabeledContent("External AI services", value: "None")
                LabeledContent("External analytics", value: "None")
                LabeledContent("Accounts", value: "None")
            } header: {
                Text("Leaving this device")
            } footer: {
                Text("Memories has no backend and no sign-in. Photo analysis uses Apple's Vision framework on this device.")
            }

            Section {
                LabeledContent("Place names", value: "Apple geocoder")
            } header: {
                Text("The one exception")
            } footer: {
                Text("When you open a photo's details and it has coordinates saved by your camera, those coordinates are sent to Apple's geocoding service to turn them into a place name. The photo itself is never sent. Everything else happens offline.")
            }

            Section {
                LabeledContent("Photos copied by Memories", value: "0")
            } header: {
                Text("Your library")
            } footer: {
                Text("Memories stores identifiers and computed details, never a second copy of your photos. Hiding a photo from Memories does not delete it, and the app never modifies your library.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.bottom, 132, for: .scrollContent)
        .task { load() }
    }

    private func load() {
        let records = LibraryQuery.allRecords(context: app.container.mainContext)
        processed = records.count
        withFeatures = records.filter { $0.featurePrint != nil }.count
    }
}

/// What the app is using on disk, and the one button that gives it back.
struct StorageView: View {
    @Environment(\.app) private var app
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
                Text("The analysis cache is the feature prints Vision produced. It is kept inside the database rather than beside it, so it is part of that figure and not added to it. Thumbnails belong to Photos and are never copied here, which is why Memories stays small even for very large libraries.")
            }

            Section {
                LabeledContent("Rows", value: "\(recordCount)")
            } footer: {
                Text("One row for each item in your library: identifiers and computed details, never a second copy of the photo.")
            }

            Section {
                Button("Clear Analysis Cache", role: .destructive) { confirmClear = true }
            } footer: {
                Text("Removes feature prints, quality scores, occasions and generated memories. Your photos are untouched, and everything is recomputed as it is needed.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.bottom, 132, for: .scrollContent)
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
        let records = LibraryQuery.allRecords(context: app.container.mainContext)
        recordCount = records.count
        analysisBytes = Self.featurePrintSize(records)
        databaseBytes = Self.storeSize()
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Feature prints are the only derived data large enough to be worth a line of its own.
    /// The scores and group assignments beside them are a handful of numbers per row, and they
    /// sit in the same store file, so they are already counted in the database figure.
    private static func featurePrintSize(_ records: [AssetRecord]) -> Int64 {
        records.reduce(Int64(0)) { $0 + Int64($1.featurePrint?.count ?? 0) }
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
