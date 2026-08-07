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

/// What one detection pass over a frame is worth.
///
/// Both halves come out of the same request deliberately. Detecting faces is the most
/// expensive thing Vision is asked for in this pipeline, and it used to be run twice over
/// every frame — once for the capture-quality number the scorer wants, and again to crop the
/// people out — which over a large library is a second full pass over every photograph for an
/// answer that was already in hand.
struct FaceFindings: Sendable {
    var count: Int = 0
    var bestQuality: Double?
    var faces: [DetectedFace] = []
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

    /// Everything one frame has to say about the people in it, from a single detection.
    ///
    /// Capture quality rather than plain rectangles: it returns the same boxes and answers
    /// "is this a usable look at them" in the same pass, and a second detection over an
    /// already-expensive decode is paid for in heat and battery.
    static func detect(in cgImage: CGImage) async -> FaceFindings {
        guard let observations = try? await DetectFaceCaptureQualityRequest().perform(on: cgImage) else {
            return FaceFindings()
        }

        var findings = FaceFindings()
        findings.count = observations.count
        findings.bestQuality = observations.compactMap { $0.captureQuality?.score }
            .map(Double.init)
            .max()
        findings.faces.reserveCapacity(observations.count)

        for observation in observations {
            let box = observation.boundingBox.cgRect
            let quality = Double(observation.captureQuality?.score ?? 0)

            // Bystanders and blurred glances are dropped here rather than being stored and
            // filtered later: a print taken from them would only ever invent people. It also
            // means the per-face print below — a Vision request of its own — is never spent
            // on a face nothing was ever going to be done with.
            guard Double(box.width * box.height) >= FaceRecord.minimumArea,
                  quality >= FaceRecord.minimumQuality,
                  let crop = squareCrop(of: cgImage, around: box),
                  let printed = try? await GenerateImageFeaturePrintRequest().perform(on: crop)
            else { continue }

            let vector = printed.featureVector
            guard !vector.isEmpty else { continue }

            findings.faces.append(DetectedFace(boundingBox: box,
                                               captureQuality: quality,
                                               featureVector: vector))
        }
        return findings
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

/// The database side of finding people.
enum PeopleIndexing {

    /// One appearance is not enough to call somebody a person.
    ///
    /// A group of one is far more often a stranger in the background, or a print that matched
    /// nothing because it was noisy, than it is somebody worth a tile on the People screen.
    static let minimumFacesPerPerson = 2

    /// The most faces one grouping pass will consider.
    ///
    /// Grouping compares every face against every group it might belong to, so its cost grows
    /// with the product of the two. Left unbounded on a library of tens of thousands it is by
    /// some distance the longest piece of arithmetic the app performs, and it lands at the end
    /// of a pass the user has already waited through. The best captures are the ones kept,
    /// which is also the half that groups reliably: a face that scored badly was never going
    /// to be matched to anybody with confidence.
    static let maxFacesConsidered = 4_000

    /// Record the faces found in a batch of frames.
    ///
    /// Batched on purpose, and without a save of its own. The rows to replace are found with
    /// one query for the whole batch rather than one per photograph, and the caller's single
    /// transaction covers the writes — a save per asset is a trip to the flash per asset.
    static func store(_ facesByAsset: [String: [DetectedFace]], in context: ModelContext) {
        guard !facesByAsset.isEmpty else { return }
        let identifiers = Array(facesByAsset.keys)

        // Replace rather than append. An asset edited in Photos is analysed again, and the
        // rows already on disk describe pixels that no longer exist.
        let descriptor = FetchDescriptor<FaceRecord>(
            predicate: #Predicate<FaceRecord> { identifiers.contains($0.assetIdentifier) }
        )
        for stale in (try? context.fetch(descriptor)) ?? [] {
            context.delete(stale)
        }

        for (identifier, faces) in facesByAsset {
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
        }
    }

    /// Group every stored face into people.
    ///
    /// A whole-library pass, so it belongs beside the other rebuilds rather than inside the
    /// per-asset loop. `moments` is handed in rather than fetched because the caller has just
    /// read every row for the other rebuilds, and reading them again for one date each would
    /// be a second materialisation of the whole table.
    static func rebuildPeople(in context: ModelContext, moments: [String: Date]) {
        guard let faces = try? context.fetch(FetchDescriptor<FaceRecord>()) else { return }
        let facesByID = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Best captures first, then the cut: what is dropped is the blurred tail, which would
        // have gone on to match nobody at the thresholds `FaceClustering` holds anyway.
        let considered = faces
            .compactMap(input(from:))
            .sorted { lhs, rhs in
                if abs(lhs.quality - rhs.quality) > 0.0001 { return lhs.quality > rhs.quality }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(maxFacesConsidered)

        let groups = FaceClustering
            .cluster(Array(considered))
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
}
