import CoreLocation
import Foundation

/// Input to clustering, kept as a plain value so the algorithms can be reasoned about and
/// tested without a database or a photo library anywhere near them.
struct ClusterInput: Sendable {
    var identifier: String
    var date: Date
    var latitude: Double?
    var longitude: Double?
    var burstIdentifier: String?
    var isVideo: Bool
    var featureVector: FeatureVector?
    var memoryScore: Double
}

// MARK: - Similarity

enum SimilarityClustering {
    /// Above this, two frames are the same shot rather than two shots of the same subject.
    static let threshold: Double = 0.92
    /// Near-duplicates are almost always seconds apart, so only a short window is compared.
    static let window: TimeInterval = 180
    static let maxComparisons = 12

    /// Groups near-identical frames and elects the best of each group.
    ///
    /// Nothing is deleted. Non-elected members simply stop competing for room inside a
    /// memory, and remain reachable through "Show all N".
    static func cluster(_ inputs: [ClusterInput]) -> [[ClusterInput]] {
        let sorted = inputs.sorted { $0.date < $1.date }
        var parent = Array(sorted.indices)

        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var walk = index
            while parent[walk] != walk { let next = parent[walk]; parent[walk] = root; walk = next }
            return root
        }

        func union(_ lhs: Int, _ rhs: Int) {
            let a = find(lhs), b = find(rhs)
            if a != b { parent[b] = a }
        }

        for index in sorted.indices {
            var compared = 0
            var back = index - 1
            while back >= 0, compared < maxComparisons {
                let candidate = sorted[back]
                guard sorted[index].date.timeIntervalSince(candidate.date) <= window else { break }
                back -= 1
                compared += 1

                // A burst is authoritative: the camera already told us these are one press.
                if let burst = sorted[index].burstIdentifier, burst == candidate.burstIdentifier {
                    union(index, back + 1)
                    continue
                }
                guard let lhs = sorted[index].featureVector, let rhs = candidate.featureVector,
                      !lhs.isEmpty, !rhs.isEmpty else { continue }
                if lhs.similarity(to: rhs) >= threshold {
                    union(index, back + 1)
                }
            }
        }

        var groups: [Int: [ClusterInput]] = [:]
        for index in sorted.indices {
            groups[find(index), default: []].append(sorted[index])
        }
        return Array(groups.values)
    }

    /// The frame that represents its group: highest quality, ties broken by the earliest
    /// shot, which is usually the one that was actually aimed.
    static func bestShot(in group: [ClusterInput]) -> ClusterInput? {
        group.max { lhs, rhs in
            if abs(lhs.memoryScore - rhs.memoryScore) > 0.001 {
                return lhs.memoryScore < rhs.memoryScore
            }
            return lhs.date > rhs.date
        }
    }

    /// Average pairwise similarity, used to tell a genuine burst from a loose grouping.
    static func averageSimilarity(in group: [ClusterInput]) -> Double {
        let vectors = group.compactMap(\.featureVector).filter { !$0.isEmpty }
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

// MARK: - Events

enum EventClustering {
    /// A gap longer than this ends an occasion. Chosen so a dinner with a lull between
    /// courses stays one event, but the next morning does not join it.
    static let gapThreshold: TimeInterval = 45 * 60
    /// Moving further than this between consecutive shots means somewhere else, whatever the clock says.
    static let distanceThreshold: CLLocationDistance = 25_000
    static let minimumCount = 4

    static func cluster(_ inputs: [ClusterInput]) -> [[ClusterInput]] {
        let sorted = inputs.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }

        var events: [[ClusterInput]] = []
        var current: [ClusterInput] = [sorted[0]]

        for item in sorted.dropFirst() {
            guard let previous = current.last else { continue }
            let gap = item.date.timeIntervalSince(previous.date)
            var breaks = gap > gapThreshold

            if !breaks, let distance = distance(previous, item), distance > distanceThreshold {
                breaks = true
            }
            // There is deliberately no calendar-day rule here. A late-night session that rolls
            // past midnight is still one night out, and any gap long enough to be worth
            // splitting on has already been split by `gapThreshold` — a day-boundary check
            // could only ever fire on a gap that rule had just declined to break, which is
            // precisely the case it must not break.

            if breaks {
                events.append(current)
                current = [item]
            } else {
                current.append(item)
            }
        }
        events.append(current)
        return events.filter { $0.count >= minimumCount }
    }

    private static func distance(_ lhs: ClusterInput, _ rhs: ClusterInput) -> CLLocationDistance? {
        guard let a = lhs.latitude, let b = lhs.longitude,
              let c = rhs.latitude, let d = rhs.longitude else { return nil }
        return CLLocation(latitude: a, longitude: b).distance(from: CLLocation(latitude: c, longitude: d))
    }

    /// How much an occasion stands out: how hard you were shooting, how long it ran, whether
    /// you bothered with video, and how good the frames turned out.
    static func significance(of group: [ClusterInput]) -> Double {
        guard let first = group.first, let last = group.last, group.count >= minimumCount else { return 0 }
        let minutes = max(1, last.date.timeIntervalSince(first.date) / 60)
        let density = min(1, Double(group.count) / minutes * 4)     // ~1 shot / 4 min saturates
        let volume = min(1, Double(group.count) / 40)
        let variety = group.contains(where: \.isVideo) ? 0.12 : 0
        let quality = group.map(\.memoryScore).reduce(0, +) / Double(group.count)
        let spread = min(1, minutes / 180)

        return min(1, density * 0.28 + volume * 0.26 + quality * 0.28 + spread * 0.10 + variety)
    }

    /// Titles an occasion from when it happened, in the app's editorial voice.
    static func title(for group: [ClusterInput]) -> String {
        guard let start = group.first?.date else { return "An occasion" }
        let hour = Calendar.current.component(.hour, from: start)
        let weekday = start.formatted(.dateTime.weekday(.wide))

        switch hour {
        case 0..<5:   return "A late night"
        case 5..<11:  return "\(weekday) morning"
        case 11..<16: return "\(weekday) afternoon"
        case 16..<20: return "\(weekday) evening"
        default:      return "\(weekday) night"
        }
    }
}
