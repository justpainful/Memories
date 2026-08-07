import Foundation
import SwiftData

/// Records what the user did, and lets it shift the ranking slightly.
///
/// This is the whole of the app's "learning". It is six numbers and a small dictionary, all
/// stored locally, all readable, all erasable from one button in Settings. Nothing is
/// profiled, nothing is sent anywhere, and no single habit is allowed to take over the feed
/// — every nudge is small and every value is clamped.
@MainActor
struct MemoryFeedback {
    let context: ModelContext

    // MARK: Exposure

    /// Called when a memory actually appears on screen, not when it is generated.
    func recordShown(_ candidate: MemoryCandidate) {
        let record = exposure(for: "memory:\(candidate.id)")
        record.count += 1
        record.lastShownAt = .now
        touchAssets(candidate.assetIdentifiers)
        context.saveIfNeeded()
    }

    func recordOpened(_ candidate: MemoryCandidate) {
        let record = exposure(for: "memory:\(candidate.id)")
        record.opened += 1
        record.lastShownAt = .now

        let preference = context.userPreference
        preference.openedCount += 1
        preference.nudgeKind(candidate.kind, by: 0.03)
        applyContentSignals(for: candidate, weight: 0.02)
        context.saveIfNeeded()
    }

    /// "Show me less like this." The strongest signal available, so it counts for the most.
    func recordDismissed(_ candidate: MemoryCandidate) {
        let record = exposure(for: "memory:\(candidate.id)")
        record.dismissed += 1
        record.lastShownAt = .now

        let preference = context.userPreference
        preference.dismissedCount += 1
        preference.nudgeKind(candidate.kind, by: -0.06)
        applyContentSignals(for: candidate, weight: -0.03)
        context.saveIfNeeded()
    }

    func recordSaved(_ candidate: MemoryCandidate) {
        let preference = context.userPreference
        preference.savedCount += 1
        preference.nudgeKind(candidate.kind, by: 0.05)
        applyContentSignals(for: candidate, weight: 0.04)
        context.saveIfNeeded()
    }

    // MARK: Per-asset

    func recordAssetSeen(_ identifiers: [String]) {
        touchAssets(identifiers)
        context.saveIfNeeded()
    }

    func setLoved(_ loved: Bool, identifier: String) {
        guard let record = asset(identifier) else { return }
        record.isLoved = loved

        let preference = context.userPreference
        if loved {
            if record.isVideo { preference.nudge(\.videoAffinity, by: 0.03) }
            if record.faceCount > 0 { preference.nudge(\.peopleAffinity, by: 0.03) }
            if record.hasLocation { preference.nudge(\.placeAffinity, by: 0.02) }
        }
        context.saveIfNeeded()
    }

    /// Hide from Memories. Not a delete — the asset is untouched in Photos and can be
    /// restored from the Hidden Memories screen.
    func setHiddenFromMemories(_ hidden: Bool, identifier: String) {
        guard let record = asset(identifier) else { return }
        record.excludedFromMemories = hidden

        if hidden {
            let preference = context.userPreference
            if record.isScreenshot { preference.nudge(\.screenshotAffinity, by: -0.05) }
            if record.isVideo { preference.nudge(\.videoAffinity, by: -0.03) }
        }
        context.saveIfNeeded()
    }

    /// Settings › Reset Memory Suggestions. Forgets the learning *and* the exposure history,
    /// so the feed genuinely starts over rather than merely re-weighting.
    func resetLearning() {
        context.userPreference.reset()
        try? context.delete(model: ExposureRecord.self)

        if let assets = try? context.fetch(FetchDescriptor<AssetRecord>()) {
            for asset in assets {
                asset.shownCount = 0
                asset.lastShownAt = nil
            }
        }
        context.saveIfNeeded()
    }

    // MARK: Plumbing

    private func applyContentSignals(for candidate: MemoryCandidate, weight: Double) {
        let preference = context.userPreference
        let records = candidate.assetIdentifiers.compactMap(asset)
        guard !records.isEmpty else { return }

        let videoShare = Double(records.filter(\.isVideo).count) / Double(records.count)
        if videoShare > 0.2 { preference.nudge(\.videoAffinity, by: weight) }

        let peopleShare = Double(records.filter { $0.faceCount > 0 }.count) / Double(records.count)
        if peopleShare > 0.3 { preference.nudge(\.peopleAffinity, by: weight) }

        if candidate.placeName != nil { preference.nudge(\.placeAffinity, by: weight) }

        let age = Date.now.timeIntervalSince(candidate.referenceDate) / 86_400
        preference.nudge(age > 730 ? \.distantPastAffinity : \.recentPastAffinity, by: weight)
    }

    private func touchAssets(_ identifiers: [String]) {
        for identifier in identifiers {
            guard let record = asset(identifier) else { continue }
            record.shownCount += 1
            record.lastShownAt = .now
        }
    }

    private func asset(_ identifier: String) -> AssetRecord? {
        var descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.localIdentifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func exposure(for key: String) -> ExposureRecord {
        var descriptor = FetchDescriptor<ExposureRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let created = ExposureRecord(key: key)
        context.insert(created)
        return created
    }
}
