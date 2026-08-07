import Foundation
import SwiftData

/// One detected face, kept so people can be grouped without ever leaving the device.
///
/// Vision publishes no face-identity embedding, so identity here is approximated: the face
/// is cropped out and run through the same feature-print request the app already uses for
/// "is this the same shot", then those prints are clustered. That is genuinely weaker than a
/// purpose-built face embedding, and the grouping is tuned to split rather than merge —
/// seeing someone twice is a small annoyance, being told two people are one is not.
@Model
final class FaceRecord {
    #Unique<FaceRecord>([\.id])
    #Index<FaceRecord>([\.assetIdentifier])

    var id: UUID = UUID()
    var assetIdentifier: String = ""

    /// Normalised bounding box, so the crop can be redrawn at any size later.
    var boundingX: Double = 0
    var boundingY: Double = 0
    var boundingWidth: Double = 0
    var boundingHeight: Double = 0

    /// Vision's own measure of how usable this capture of the face is.
    var captureQuality: Double = 0
    var featurePrint: Data?
    var personID: UUID?
    var analysisVersion: Int = 0

    init(assetIdentifier: String) {
        self.assetIdentifier = assetIdentifier
    }

    /// Faces smaller than this are usually bystanders, and their prints are too noisy to
    /// cluster on. Grouping them would produce people who do not exist.
    static let minimumArea: Double = 0.012
    static let minimumQuality: Double = 0.35

    var area: Double { boundingWidth * boundingHeight }
    var isUsableForGrouping: Bool {
        area >= Self.minimumArea && captureQuality >= Self.minimumQuality && featurePrint != nil
    }
}

/// A group of faces the app believes belong to one person.
///
/// Unnamed until the user says otherwise. The app never guesses at names and has nowhere to
/// look them up from — there is no contacts access and no network.
@Model
final class PersonRecord {
    #Unique<PersonRecord>([\.id])

    var id: UUID = UUID()
    var name: String?
    var coverAssetIdentifier: String?
    /// Normalised box of the cover face, so the list can show the face rather than the photo.
    var coverBoundingX: Double = 0
    var coverBoundingY: Double = 0
    var coverBoundingWidth: Double = 1
    var coverBoundingHeight: Double = 1

    var faceCount: Int = 0
    var assetIdentifiers: [String] = []
    var firstSeen: Date = Date.distantPast
    var lastSeen: Date = Date.distantPast
    /// Set when the user hides someone from memories, the way a photo can be hidden.
    var isHidden: Bool = false
    var createdAt: Date = Date.now

    init(id: UUID = UUID()) {
        self.id = id
    }

    var displayName: String { name ?? "Unnamed" }
    var isNamed: Bool { name?.isEmpty == false }
}

/// Makes "hide this person" mean something.
///
/// The switch on a person had been writing `isHidden` since it was built, and nothing in the
/// app had ever read it — the photographs kept coming back in memories, which is the one thing
/// the control promises not to let happen. The flag was a note to nobody.
///
/// The reconciliation is a full recompute rather than a diff of the person who just changed.
/// A photograph can hold more than one person, so hiding Alice must not un-hide a photograph
/// that also has Bob in it, and bringing Alice back must not bring back the ones that are still
/// Bob's. Deriving the whole set from the whole truth is the only version of this that cannot
/// drift, and it costs one pass over the people table — tens of rows, not tens of thousands.
enum PersonVisibility {

    /// Bring every asset's `hiddenByPerson` flag back in line with who is currently hidden.
    @MainActor
    static func reconcile(context: ModelContext) {
        let people = (try? context.fetch(FetchDescriptor<PersonRecord>())) ?? []
        var shouldBeHidden: Set<String> = []
        for person in people where person.isHidden {
            shouldBeHidden.formUnion(person.assetIdentifiers)
        }

        // Fetched whole rather than by predicate on the identifier set: the set can be
        // thousands of strings, and `contains` over a bound array of that size is a predicate
        // SwiftData translates into a query no index can help with.
        let assets = (try? context.fetch(FetchDescriptor<AssetRecord>())) ?? []
        var changed = false
        for asset in assets {
            let wanted = shouldBeHidden.contains(asset.localIdentifier)
            if asset.hiddenByPerson != wanted {
                asset.hiddenByPerson = wanted
                changed = true
            }
        }
        if changed { context.saveIfNeeded() }
    }

    /// Hide or show one person, and put the library in step with the decision.
    @MainActor
    static func setHidden(_ hidden: Bool, person: PersonRecord, context: ModelContext) {
        guard person.isHidden != hidden else { return }
        person.isHidden = hidden
        context.saveIfNeeded()
        reconcile(context: context)
    }
}
