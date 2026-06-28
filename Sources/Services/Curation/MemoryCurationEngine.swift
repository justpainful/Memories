import Foundation

protocol MemoryRandomizing: Sendable {
    func nextIndex(upperBound: Int) async -> Int
}

struct SystemMemoryRandomizer: MemoryRandomizing {
    func nextIndex(upperBound: Int) async -> Int {
        Int.random(in: 0..<upperBound)
    }
}

actor SeededMemoryRandomizer: MemoryRandomizing {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    func nextIndex(upperBound: Int) async -> Int {
        guard upperBound > 0 else {
            return 0
        }

        state = 2862933555777941757 &* state &+ 3037000493
        return Int(state % UInt64(upperBound))
    }
}

struct DefaultMemoryCurationScorer: MemoryCurationScoring {
    func score(candidate: MemoryCandidate, context: MemoryScoringContext) -> Double {
        guard candidate.status == .eligible else {
            return -.greatestFiniteMagnitude
        }

        var score = deterministicJitter(for: candidate.localIdentifier, currentDate: context.currentDate)

        if candidate.isFavorite {
            score += 30
        }

        if context.recentlyViewedIdentifiers.contains(candidate.localIdentifier) {
            score -= 500
        }

        if let previousCandidate = context.previousCandidate {
            if previousCandidate.localIdentifier == candidate.localIdentifier {
                score -= 1_000
            }
            if previousCandidate.burstIdentifier != nil && previousCandidate.burstIdentifier == candidate.burstIdentifier {
                score -= 80
            }
            if let lhs = previousCandidate.creationDate,
               let rhs = candidate.creationDate,
               Calendar.current.isDate(lhs, inSameDayAs: rhs) {
                score -= 20
            }
        }

        if let creationDate = candidate.creationDate {
            let calendar = Calendar.current
            let currentMonthDay = calendar.dateComponents([.month, .day], from: context.currentDate)
            let candidateMonthDay = calendar.dateComponents([.month, .day], from: creationDate)
            if currentMonthDay.month == candidateMonthDay.month && currentMonthDay.day == candidateMonthDay.day {
                score += 40
            }
            if calendar.component(.weekOfYear, from: creationDate) == calendar.component(.weekOfYear, from: context.currentDate) {
                score += 12
            }
        }

        switch candidate.mediaKind {
        case .livePhoto:
            score += 8
        case .video:
            score += 4
        case .photo:
            break
        }

        return score
    }

    private func deterministicJitter(for identifier: String, currentDate: Date) -> Double {
        let dayBucket = UInt64(max(0, Int(currentDate.timeIntervalSinceReferenceDate / 86_400)))
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= dayBucket
        hash &*= 1_099_511_628_211
        return Double(hash % 10_000) / 10_000
    }
}

struct MemoryCycleResult: Sendable {
    var signature: MemoryCycleSignature
    var orderedCandidates: [MemoryCandidate]
    var viewedIdentifiers: [String]
    var exhausted: Bool
}

struct MemoryCurationEngine: Sendable {
    let scorer: any MemoryCurationScoring
    let cycleStore: any MemoryCycleStore
    let randomizer: any MemoryRandomizing
    let now: @Sendable () -> Date

    init(
        scorer: any MemoryCurationScoring = DefaultMemoryCurationScorer(),
        cycleStore: any MemoryCycleStore,
        randomizer: any MemoryRandomizing = SystemMemoryRandomizer(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scorer = scorer
        self.cycleStore = cycleStore
        self.randomizer = randomizer
        self.now = now
    }

    func curateCycle(
        from candidates: [MemoryCandidate],
        filter: MemoryFilter
    ) async throws -> MemoryCycleResult {
        let signature = MemoryCycleSignature(filter: filter)
        let viewedIdentifiers = try await cycleStore.viewedIdentifiers(for: signature)
        let viewedSet = Set(viewedIdentifiers)

        let eligible = candidates.filter { $0.status == .eligible }
        guard !eligible.isEmpty else {
            return MemoryCycleResult(
                signature: signature,
                orderedCandidates: [],
                viewedIdentifiers: viewedIdentifiers,
                exhausted: true
            )
        }

        var remaining = eligible.filter { !viewedSet.contains($0.localIdentifier) }
        if remaining.isEmpty {
            return MemoryCycleResult(
                signature: signature,
                orderedCandidates: [],
                viewedIdentifiers: viewedIdentifiers,
                exhausted: true
            )
        }

        let ordered: [MemoryCandidate]
        switch filter.selectionMode {
        case .smartRandom:
            ordered = orderSmartRandom(remaining, alreadyViewed: viewedSet)
        case .pureRandom:
            ordered = await orderPureRandom(remaining)
        }

        return MemoryCycleResult(
            signature: signature,
            orderedCandidates: ordered,
            viewedIdentifiers: viewedIdentifiers,
            exhausted: ordered.isEmpty
        )
    }

    func nextCandidate(
        from candidates: [MemoryCandidate],
        filter: MemoryFilter,
        previousCandidate: MemoryCandidate? = nil
    ) async throws -> MemoryCandidate? {
        let signature = MemoryCycleSignature(filter: filter)
        let viewedIdentifiers = Set(try await cycleStore.viewedIdentifiers(for: signature))
        let eligible = candidates.filter { $0.status == .eligible }
        guard !eligible.isEmpty else {
            return nil
        }

        var remaining = eligible.filter { !viewedIdentifiers.contains($0.localIdentifier) }
        if remaining.isEmpty {
            return nil
        }

        let selectionPool = filteredSelectionPool(remaining, previousCandidate: previousCandidate)
        let currentDate = now()
        let context = MemoryScoringContext(
            currentDate: currentDate,
            recentlyViewedIdentifiers: viewedIdentifiers,
            previousCandidate: previousCandidate
        )

        let candidate: MemoryCandidate
        switch filter.selectionMode {
        case .smartRandom:
            candidate = selectionPool.max { lhs, rhs in
                let lhsScore = scorer.score(candidate: lhs, context: context)
                let rhsScore = scorer.score(candidate: rhs, context: context)
                if lhsScore == rhsScore {
                    return lhs.localIdentifier > rhs.localIdentifier
                }
                return lhsScore < rhsScore
            } ?? selectionPool[0]
        case .pureRandom:
            let index = await randomizer.nextIndex(upperBound: selectionPool.count)
            candidate = selectionPool[index]
        }

        try await cycleStore.recordViewed(identifier: candidate.localIdentifier, signature: signature)
        return candidate
    }

    func recordViewed(_ candidate: MemoryCandidate, signature: MemoryCycleSignature) async throws {
        try await cycleStore.recordViewed(identifier: candidate.localIdentifier, signature: signature)
    }

    func resetCycle(for filter: MemoryFilter) async throws {
        try await cycleStore.resetCycle(for: MemoryCycleSignature(filter: filter))
    }

    private func orderSmartRandom(
        _ candidates: [MemoryCandidate],
        alreadyViewed: Set<String>
    ) -> [MemoryCandidate] {
        var ordered: [MemoryCandidate] = []
        var remaining = candidates
        var previousCandidate: MemoryCandidate?
        let currentDate = now()

        while !remaining.isEmpty {
            let pool = filteredSelectionPool(remaining, previousCandidate: previousCandidate)
            let context = MemoryScoringContext(
                currentDate: currentDate,
                recentlyViewedIdentifiers: alreadyViewed.union(ordered.map(\.localIdentifier)),
                previousCandidate: previousCandidate
            )

            let next = pool.max { lhs, rhs in
                let lhsScore = scorer.score(candidate: lhs, context: context)
                let rhsScore = scorer.score(candidate: rhs, context: context)
                if lhsScore == rhsScore {
                    return lhs.localIdentifier > rhs.localIdentifier
                }
                return lhsScore < rhsScore
            } ?? pool[0]

            ordered.append(next)
            previousCandidate = next
            remaining.removeAll { $0.localIdentifier == next.localIdentifier }
        }

        return ordered
    }

    private func orderPureRandom(_ candidates: [MemoryCandidate]) async -> [MemoryCandidate] {
        var remaining = candidates
        var ordered: [MemoryCandidate] = []
        var previousCandidate: MemoryCandidate?

        while !remaining.isEmpty {
            let pool = filteredSelectionPool(remaining, previousCandidate: previousCandidate)
            let index = await randomizer.nextIndex(upperBound: pool.count)
            let next = pool[index]
            ordered.append(next)
            previousCandidate = next
            remaining.removeAll { $0.localIdentifier == next.localIdentifier }
        }

        return ordered
    }

    private func filteredSelectionPool(
        _ candidates: [MemoryCandidate],
        previousCandidate: MemoryCandidate?
    ) -> [MemoryCandidate] {
        guard let previousCandidate, candidates.count > 1 else {
            return candidates
        }

        let filtered = candidates.filter { $0.localIdentifier != previousCandidate.localIdentifier }
        return filtered.isEmpty ? candidates : filtered
    }
}
