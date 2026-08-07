import Foundation

/// Input to face grouping, kept as a plain value so the algorithm can be reasoned about and
/// tested without a database, a photo library or Vision anywhere near it.
struct FaceInput: Sendable, Equatable {
    /// Identifies the face row this came from, so the caller can find its box again.
    var id: UUID
    var assetIdentifier: String
    var quality: Double
    /// Share of the frame the face occupies, 0...1.
    var area: Double
    var featureVector: FeatureVector
}

/// Groups face prints into people.
///
/// **What this is standing on.** Vision publishes no face-identity embedding. The prints being
/// compared here come from `GenerateImageFeaturePrintRequest`, which describes what a picture
/// looks like — trained on pictures in general, not on telling one person from another. It is
/// genuinely weaker than a purpose-built face embedding: it is swayed by lighting, by angle,
/// by what somebody is wearing and by the wall behind them, none of which is identity.
///
/// **So it is tuned to split.** Every threshold below is set high, and every ambiguous case
/// resolves to "a new person" rather than "probably that one". The cost of that is real —
/// somebody photographed over ten years will show up as two or three people, and the user has
/// to name each. The cost of the other bias is worse: telling somebody two people are one is
/// the app asserting something false about their life, and no amount of convenience is worth
/// it. Splitting is a chore; merging is a lie.
enum FaceClustering {

    /// A face has to look this much like the best match in a group before it can join at all.
    ///
    /// Cosine similarity between these prints runs high across the board — two unrelated
    /// portraits sit well above zero simply for being portraits — so the interesting range is
    /// narrow and near the top. 0.88 sits deliberately inside it rather than at the midpoint.
    static let joinThreshold: Double = 0.88

    /// And it has to hold up against the group as a whole, not just its single best match.
    static let cohesionThreshold: Double = 0.84

    /// If the two best-fitting groups are within this of each other, the face joins neither.
    ///
    /// A face that fits two people equally well is not evidence for either of them; it is
    /// evidence that the print cannot tell them apart.
    static let ambiguityMargin: Double = 0.02

    /// A group is represented by its best few faces rather than all of them, so a person with
    /// four hundred photographs does not cost four hundred comparisons each time.
    static let maxComparisonsPerPerson = 8

    /// The most people one pass will invent.
    ///
    /// Every face is weighed against every group, so an unbounded number of groups makes the
    /// work grow with the square of the library — and almost all of that growth is spent on
    /// groups of one, which are thrown away afterwards for being too small to be anybody.
    /// Past this a face that matches nobody is simply left out.
    static let maxGroups = 600

    /// Groups faces into people. Order in, order out: the same library always produces the
    /// same people, which is what makes the result testable and the screen stable between runs.
    static func cluster(_ faces: [FaceInput]) -> [[FaceInput]] {
        // Best captures first, so each group is seeded by a clear photograph of somebody
        // rather than by whichever blurred one happened to be first in the library. The
        // identifier breaks ties so equal-quality faces do not shuffle between runs.
        let ordered = faces
            .filter { !$0.featureVector.isEmpty }
            .sorted { lhs, rhs in
                if abs(lhs.quality - rhs.quality) > 0.0001 { return lhs.quality > rhs.quality }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        var groups: [[FaceInput]] = []

        for face in ordered {
            // This is the longest-running loop in the app, and it runs at the very end of a
            // pass. Without this, asking it to stop — closing the app, reindexing — waits for
            // every remaining face.
            if Task.isCancelled { break }

            var best: (index: Int, score: Double)?
            var runnerUp: Double = 0

            for (index, group) in groups.enumerated() {
                // Two faces in one photograph are two people. The camera cannot catch anybody
                // twice in one exposure, so this is one of the few things here that is a fact
                // rather than a guess — and it blocks a merge the print alone would happily
                // make between siblings sitting next to each other.
                guard !group.contains(where: { $0.assetIdentifier == face.assetIdentifier }),
                      let score = affinity(of: face, to: group)
                else { continue }

                if score > (best?.score ?? -1) {
                    if let previous = best { runnerUp = max(runnerUp, previous.score) }
                    best = (index, score)
                } else {
                    runnerUp = max(runnerUp, score)
                }
            }

            if let best, best.score - runnerUp > ambiguityMargin {
                groups[best.index].append(face)
            } else if groups.count < maxGroups {
                groups.append([face])
            }
        }

        return groups.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.first?.id.uuidString ?? "") < (rhs.first?.id.uuidString ?? "")
        }
    }

    /// How well a face fits a group, or nil when it does not fit at all.
    ///
    /// Two tests, not one. The best match has to be strong, which is the ordinary "do these
    /// look alike" question. But the average across the group has to hold up as well, and
    /// that is what stops a chain forming: A resembles B, B resembles C, and a rule that only
    /// asked about the closest match would then call A and C the same person however little
    /// they actually have in common. Chains are how face grouping usually goes wrong.
    static func affinity(of face: FaceInput, to group: [FaceInput]) -> Double? {
        let sample = group
            .sorted { $0.quality > $1.quality }
            .prefix(maxComparisonsPerPerson)
        guard !sample.isEmpty else { return nil }

        var best = 0.0, total = 0.0
        for member in sample {
            let score = face.featureVector.similarity(to: member.featureVector)
            best = max(best, score)
            total += score
        }

        let average = total / Double(sample.count)
        guard best >= joinThreshold, average >= cohesionThreshold else { return nil }
        return average
    }

    /// The face that stands for a person: the best capture, ties broken by the largest, which
    /// at equal quality is the photograph taken closer to them.
    static func cover(of group: [FaceInput]) -> FaceInput? {
        group.max { lhs, rhs in
            if abs(lhs.quality - rhs.quality) > 0.0001 { return lhs.quality < rhs.quality }
            if abs(lhs.area - rhs.area) > 0.0001 { return lhs.area < rhs.area }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    /// Average pairwise similarity within a group — how tightly it actually holds together,
    /// as opposed to how tightly the thresholds required it to.
    static func averageSimilarity(in group: [FaceInput]) -> Double {
        let vectors = group.map(\.featureVector).filter { !$0.isEmpty }
        guard vectors.count > 1 else { return 1 }

        var total = 0.0, pairs = 0
        for i in 0..<(vectors.count - 1) {
            for j in (i + 1)..<vectors.count {
                total += vectors[i].similarity(to: vectors[j])
                pairs += 1
            }
        }
        return pairs > 0 ? total / Double(pairs) : 1
    }
}
