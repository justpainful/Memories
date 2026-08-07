import SwiftData
import SwiftUI

/// Memories the user chose to keep.
///
/// Wider than an album on purpose: a collection can hold a whole occasion or a whole day,
/// not only loose files, so "Favourite Nights" can mean the nights rather than 200 photos.
struct CollectionsView: View {
    @Environment(\.app) private var app
    @Query(sort: \CollectionRecord.sortIndex) private var collections: [CollectionRecord]
    @State private var isCreating = false
    @State private var newName = ""

    var body: some View {
        Group {
            if collections.isEmpty {
                QuietStatusView(
                    title: "No collections yet",
                    detail: "Keep a memory, an occasion or a whole day here and it will stay put.",
                    symbol: "folder"
                )
            } else {
                List {
                    ForEach(collections) { collection in
                        NavigationLink {
                            CollectionDetailView(collection: collection)
                        } label: {
                            HStack(spacing: Space.l) {
                                if let cover = collection.coverIdentifier {
                                    PhotoThumbnail(identifier: cover, side: 54, radius: Radius.thumb)
                                } else {
                                    RoundedRectangle(cornerRadius: Radius.thumb)
                                        .fill(Palette.surfaceSunk)
                                        .frame(width: 54, height: 54)
                                        .overlay {
                                            Image(systemName: "folder")
                                                .foregroundStyle(Palette.textTertiary)
                                        }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name)
                                        .font(Typo.label)
                                        .foregroundStyle(Palette.textPrimary)
                                    Text("\(collection.itemCount) \(collection.itemCount == 1 ? "item" : "items")")
                                        .font(Typo.meta)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 132, for: .scrollContent)
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New collection")
            }
        }
        .alert("New collection", isPresented: $isCreating) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty else { return }
        let context = app.container.mainContext
        let collection = CollectionRecord(name: name)
        collection.sortIndex = collections.count
        context.insert(collection)
        context.saveIfNeeded()
    }

    private func delete(at offsets: IndexSet) {
        let context = app.container.mainContext
        for index in offsets { context.delete(collections[index]) }
        context.saveIfNeeded()
    }
}

struct CollectionDetailView: View {
    let collection: CollectionRecord

    @Environment(\.app) private var app
    @State private var records: [AssetRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                if !nonAssetItems.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Also kept").overlineStyle()
                        ForEach(nonAssetItems) { item in
                            Text(describe(item))
                                .font(Typo.label)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s)
                }

                AssetGridView(
                    records: records,
                    emptyTitle: "Nothing kept here yet",
                    emptyDetail: "Add a memory from its ••• menu.",
                    emptySymbol: "folder"
                )
            }
            .padding(.bottom, 132)
        }
        .scrollIndicators(.hidden)
        .background(Palette.canvas)
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private var nonAssetItems: [CollectionItem] {
        collection.items.filter { $0.kind != .asset }
    }

    private func describe(_ item: CollectionItem) -> String {
        switch item.kind {
        case .event:  return "An occasion"
        case .day:    return item.reference
        case .memory: return "A memory"
        case .asset:  return ""
        }
    }

    private func load() {
        records = LibraryQuery.records(for: collection.assetReferences,
                                       context: app.container.mainContext)
    }
}

/// Pick or create a collection for whatever is being kept.
struct AddToCollectionSheet: View {
    let items: [CollectionItem]
    let suggestedCover: String?

    @Environment(\.app) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CollectionRecord.sortIndex) private var collections: [CollectionRecord]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Keep in") {
                    ForEach(collections) { collection in
                        Button {
                            add(to: collection)
                        } label: {
                            HStack {
                                Text(collection.name).foregroundStyle(Palette.textPrimary)
                                Spacer()
                                Text("\(collection.itemCount)")
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .font(Typo.label)
                        }
                    }
                }
                Section("New collection") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") { createAndAdd() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func add(to collection: CollectionRecord) {
        collection.items.append(contentsOf: items)
        collection.updatedAt = .now
        if collection.coverIdentifier == nil { collection.coverIdentifier = suggestedCover }
        app.container.mainContext.saveIfNeeded()
        Haptics.impact(.light)
        dismiss()
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let context = app.container.mainContext
        let collection = CollectionRecord(name: name)
        collection.sortIndex = collections.count
        context.insert(collection)
        add(to: collection)
    }
}
