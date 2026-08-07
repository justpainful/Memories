import Photos

/// The heart, and the fact that it belongs to Photos rather than to this app.
///
/// Loving a photograph sets `PHAsset.isFavorite` on the asset itself — the very flag the
/// Photos app's own heart writes. Anything less leaves this app quietly disagreeing with
/// Photos for as long as both are installed: the user hearts a picture here, opens Photos,
/// and finds it unfavourited. From the outside that is indistinguishable from a dead button.
///
/// Nothing in here touches the local rows. The caller writes those first so the heart fills
/// in under the finger, and puts them back if this reports a failure.
enum Loved {

    /// Why the library would not take the change, in words that mean something to the person
    /// holding the phone. Every one of these was previously a silent no-op.
    enum Failure {
        case noAccess
        case gone
        case notEditable
        case refused

        /// Typographic apostrophes rather than ASCII ticks. These four sentences are the only
        /// thing the user is ever shown when the heart fails, and a vertical `'` is the single
        /// most reliable tell that a screen was not written by Apple.
        var message: String {
            switch self {
            case .noAccess:    return "Memories can’t change your library"
            case .gone:        return "No longer in your library"
            case .notEditable: return "Photos won’t allow this change"
            case .refused:     return "Photos didn’t save that"
            }
        }
    }

    /// Writes the favourite flag through to the library. `nil` means it landed.
    ///
    /// The whole batch goes in one change request rather than one per photograph, because
    /// Photos treats a change request as a single undoable operation and a selection of forty
    /// should be one of those, not forty.
    static func write(_ loved: Bool, identifiers: [String]) async -> Failure? {
        guard !identifiers.isEmpty else { return nil }

        // Changing an existing asset requires read-write authorization. `.addOnly` is enough
        // to put a *new* photo into the library and no more, and a change request made
        // without the right level fails inside `performChanges` rather than at the call site
        // — so without this the only symptom is a heart that never stays filled.
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            break
        default:
            return .noAccess
        }

        let assets = Array(PhotoLibraryService.assets(for: identifiers).values)
        guard !assets.isEmpty else { return .gone }

        let succeeded: Bool = await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                for asset in assets {
                    let request = PHAssetChangeRequest(for: asset)
                    request.isFavorite = loved
                }
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard !succeeded else { return nil }

        // Photos refuses a property change on anything the user does not own outright — an
        // iTunes-synced asset, or one outside a Limited Access selection. Saying which of the
        // two happened is more use than repeating that something went wrong.
        let editable = assets.contains(where: { $0.canPerform(.properties) })
        return editable ? .refused : .notEditable
    }

    static func write(_ loved: Bool, identifier: String) async -> Failure? {
        await write(loved, identifiers: [identifier])
    }

    /// What the library itself says about one asset right now.
    ///
    /// The local row is only ever as fresh as the last indexing pass, so a picture favourited
    /// in the Photos app a minute ago would otherwise open here with an empty heart — the
    /// same disagreement, arriving from the other direction.
    static func libraryFavorite(identifier: String) async -> Bool? {
        PhotoLibraryService.asset(for: identifier)?.isFavorite
    }
}
