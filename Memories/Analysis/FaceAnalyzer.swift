import CoreGraphics
import SwiftData
import UIKit
import Vision

/// One face found in one frame, before it belongs to anybody.
struct DetectedFace: Sendable {
    /// Normalised, in Vision's coordinate space — origin at the lower left of the frame.
    var boundingBox: CGRect
    var captureQuality: Double
    var featureVector: FeatureVector

    var area: Double { Double(boundingBox.width * boundingBox.height) }
}

/// Finds the faces in one already-decoded frame and describes each well enough to group later.
///
/// Vision publishes no face-identity embedding, so identity here is approximated: the face is
/// cropped out and run through `GenerateImageFeaturePrintRequest`, the same request the app
/// already uses for "is this the same shot". That print was trained to describe pictures, not
/// people, so everything downstream of it is a best guess — see `FaceClustering` for how far
/// that guess is trusted.
///
/// Everything is Apple's Vision framework running locally. No network, no model downloads.
enum FaceAnalyzer {

    /// The crop is taken this much wider than Vision's box, on every side.
    ///
    /// Vision's box is tight to the features, and a tight crop throws away hair, jaw and ears
    /// — which is most of what makes two photographs of one person look like one person to a
    /// print that was never taught what a face is.
    static let cropMargin: CGFloat = 0.45

    /// Below this the crop is a handful of pixels and its print is noise wearing a number.
    static let minimumCropPixels: CGFloat = 24

    /// Convenience for the indexing pipeline, which already holds a decoded `UIImage`.
    static func faces(in image: UIImage) async -> [DetectedFace] {
        guard let cgImage = image.cgImage else { return [] }
        return await faces(in: cgImage)
    }

    static func faces(in cgImage: CGImage) async -> [DetectedFace] {
        // Capture quality rather than plain rectangles: it returns the same boxes and answers
        // "is this a usable look at them" in the same pass, and a second detection pass over
        // an already-expensive decode would be paid for in heat and battery.
        guard let observations = try? await DetectFaceCaptureQualityRequest().perform(on: cgImage) else {
            return []
        }

        var found: [DetectedFace] = []
        found.reserveCapacity(observations.count)

        for observation in observations {
            let box = observation.boundingBox.cgRect
            let quality = Double(observation.captureQuality?.score ?? 0)

            // Bystanders and blurred glances are dropped here rather than being stored and
            // filtered later: a print taken from them would only ever invent people.
            guard Double(box.width * box.height) >= FaceRecord.minimumArea,
                  quality >= FaceRecord.minimumQuality,
                  let crop = squareCrop(of: cgImage, around: box),
                  let printed = try? await GenerateImageFeaturePrintRequest().perform(on: crop)
            else { continue }

            let vector = printed.featureVector
            guard !vector.isEmpty else { continue }

            found.append(DetectedFace(boundingBox: box,
                                      captureQuality: quality,
                                      featureVector: vector))
        }
        return found
    }

    /// A square crop around the face, taken wider than the box Vision drew.
    ///
    /// Square because the feature-print request scales whatever it is handed to its own input
    /// size: letting one crop arrive at 3:4 and the next at 1:1 would put a difference in the
    /// prints that has nothing to do with who is in them.
    private static func squareCrop(of cgImage: CGImage, around box: CGRect) -> CGImage? {
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }

        // Vision measures from the lower left; `CGImage` crops from the upper left.
        let centreX = box.midX * width
        let centreY = (1 - box.midY) * height
        let side = max(box.width * width, box.height * height) * (1 + 2 * cropMargin)
        guard side >= minimumCropPixels else { return nil }

        // Slide the window back inside the frame before clipping it, so somebody standing at
        // the edge of the shot still gets a square crop rather than a sliver of one.
        var origin = CGPoint(x: centreX - side / 2, y: centreY - side / 2)
        origin.x = min(max(0, origin.x), max(0, width - side))
        origin.y = min(max(0, origin.y), max(0, height - side))

        let rect = CGRect(x: origin.x, y: origin.y, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            .integral
        guard rect.width >= minimumCropPixels, rect.height >= minimumCropPixels else { return nil }
        return cgImage.cropping(to: rect)
    }
}

// MARK: - Entry point for the indexing pipeline

/// The database side of finding people. Nothing calls this yet.
///
/// The face pass is deliberately not wired into `AnalysisCoordinator` here — that file belongs
/// to another pass of work. Two calls connect it, and both are noted on the functions below.
enum PeopleIndexing {

    /// One appearance is not enough to call somebody a person.
    ///
    /// A group of one is far more often a stranger in the background, or a print that matched
    /// nothing because it was noisy, than it is somebody worth a tile on the People screen.
    static let minimumFacesPerPerson = 2

    /// Record the faces found in one frame.
    ///
    /// **Wiring:** call from `AnalysisCoordinator.runPixels`, immediately after
    /// `await indexer.store(analysis, for: identifier)`, with the same decoded image.
    static func store(_ faces: [DetectedFace], for identifier: String, in context: ModelContext) {
        // Replace rather than append. An asset edited in Photos is analysed again, and the
        // rows already on disk describe pixels that no longer exist.
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate { $0.assetIdentifier == identifier }
        )
        for stale in (try? context.fetch(descriptor)) ?? [] {
            context.delete(stale)
        }

        for face in faces {
            let record = FaceRecord(assetIdentifier: identifier)
            record.boundingX = Double(face.boundingBox.minX)
            record.boundingY = Double(face.boundingBox.minY)
            record.boundingWidth = Double(face.boundingBox.width)
            record.boundingHeight = Double(face.boundingBox.height)
            record.captureQuality = face.captureQuality
            record.featurePrint = face.featureVector.data
            record.analysisVersion = currentAnalysisVersion
            context.insert(record)
        }
        context.saveIfNeeded()
    }

    /// Group every stored face into people.
    ///
    /// **Wiring:** call once after the pixel pass, next to `await indexer.rebuildEvents()`.
    /// It is a whole-library pass, so it belongs beside the other rebuilds rather than inside
    /// the per-asset loop.
    static func rebuildPeople(in context: ModelContext) {
        guard let faces = try? context.fetch(FetchDescriptor<FaceRecord>()) else { return }
        let facesByID = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let groups = FaceClustering
            .cluster(faces.compactMap(input(from:)))
            .filter { $0.count >= minimumFacesPerPerson }

        // Who each face used to belong to, read before the assignments are cleared.
        var formerOwner: [UUID: UUID] = [:]
        for face in faces {
            if let personID = face.personID { formerOwner[face.id] = personID }
            face.personID = nil
        }

        var unclaimed = Dictionary(
            ((try? context.fetch(FetchDescriptor<PersonRecord>())) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let moments = momentDates(in: context)

        for group in groups {
            // Grouping is redone from scratch on every pass, so without this a person the
            // user took the trouble to name would go back to "Unnamed" each time. Whichever
            // person most of the group used to belong to keeps their name and their hiding.
            var votes: [UUID: Int] = [:]
            for member in group {
                if let previous = formerOwner[member.id] { votes[previous, default: 0] += 1 }
            }
            let inherited = votes
                .filter { unclaimed[$0.key] != nil }
                .max { ($0.value, $0.key.uuidString) < ($1.value, $1.key.uuidString) }?
                .key

            let person: PersonRecord
            if let inherited, let reused = unclaimed.removeValue(forKey: inherited) {
                person = reused
            } else {
                person = PersonRecord()
                context.insert(person)
            }

            apply(group, to: person, faces: facesByID, moments: moments)
            for member in group {
                if let record = facesByID[member.id] { record.personID = person.id }
            }
        }

        // Whoever is left over no longer has a group behind them. Their name goes with them,
        // which is the honest outcome: the app is no longer claiming to have found them.
        for leftover in unclaimed.values { context.delete(leftover) }
        context.saveIfNeeded()
    }

    private static func input(from face: FaceRecord) -> FaceInput? {
        guard face.isUsableForGrouping,
              let vector = face.featurePrint.flatMap(FeatureVector.init(data:)),
              !vector.isEmpty
        else { return nil }

        return FaceInput(id: face.id,
                         assetIdentifier: face.assetIdentifier,
                         quality: face.captureQuality,
                         area: face.area,
                         featureVector: vector)
    }

    private static func apply(_ group: [FaceInput],
                              to person: PersonRecord,
                              faces: [UUID: FaceRecord],
                              moments: [String: Date]) {
        if let cover = FaceClustering.cover(of: group), let record = faces[cover.id] {
            person.coverAssetIdentifier = record.assetIdentifier
            person.coverBoundingX = record.boundingX
            person.coverBoundingY = record.boundingY
            person.coverBoundingWidth = record.boundingWidth
            person.coverBoundingHeight = record.boundingHeight
        }

        person.faceCount = group.count
        // One entry per photograph: somebody caught twice in one frame is still one photo.
        let identifiers = Array(Set(group.map(\.assetIdentifier)))
        person.assetIdentifiers = identifiers.sorted {
            (moments[$0] ?? .distantPast) > (moments[$1] ?? .distantPast)
        }

        let dates = identifiers.compactMap { moments[$0] }
        person.firstSeen = dates.min() ?? .distantPast
        person.lastSeen = dates.max() ?? .distantPast
    }

    /// When each asset actually happened, preferring a recovered capture date, so a person's
    /// span reads as the years you knew them rather than the day the files arrived.
    private static func momentDates(in context: ModelContext) -> [String: Date] {
        guard let records = try? context.fetch(FetchDescriptor<AssetRecord>()) else { return [:] }
        return Dictionary(records.map { ($0.localIdentifier, $0.momentDate) },
                          uniquingKeysWith: { first, _ in first })
    }
}
