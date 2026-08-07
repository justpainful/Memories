import Foundation
import Testing
@testable import Memories

/// `passes` is the gate every asset goes through before it can appear anywhere. It is a pure
/// function over one row, so it can be proven exhaustively without a store behind it.
struct LibraryQueryTests {

    @Test("An ordinary photo passes the default gate")
    func ordinaryPhotoPasses() {
        #expect(LibraryQuery.passes(Fixture.asset("photo"), options: CurationOptions()))
    }

    @Test("Screenshots stay out of memories until they are asked for")
    func screenshotsExcludedByDefault() {
        let shot = Fixture.asset("shot", isScreenshot: true)
        #expect(LibraryQuery.passes(shot, options: CurationOptions()) == false)

        var wanted = CurationOptions()
        wanted.includeScreenshots = true
        #expect(LibraryQuery.passes(shot, options: wanted))

        // Browsing is meant to show the library as it is, screenshots included.
        #expect(LibraryQuery.passes(shot, options: .browsing))
    }

    @Test("Hidden from Memories means hidden everywhere but the Hidden screen")
    func hiddenIsExcluded() {
        let hidden = Fixture.asset("hidden", hidden: true)
        #expect(LibraryQuery.passes(hidden, options: CurationOptions()) == false)
        // Even browsing does not show it — only the one screen that asks for it explicitly.
        #expect(LibraryQuery.passes(hidden, options: .browsing) == false)

        var hiddenScreen = CurationOptions()
        hiddenScreen.includeHiddenFromMemories = true
        #expect(LibraryQuery.passes(hidden, options: hiddenScreen))
    }

    @Test("An asset that lives only in iCloud is kept out of memories but not out of browsing")
    func cloudOnlyIsExcludedFromMemories() {
        let cloud = Fixture.asset("cloud", locallyAvailable: false)
        #expect(LibraryQuery.passes(cloud, options: CurationOptions()) == false)
        #expect(LibraryQuery.passes(cloud, options: .browsing))
    }

    @Test("The media filter admits only what it names")
    func mediaFilterAdmitsOnlyItsOwn() {
        let photo = Fixture.asset("photo")
        let video = Fixture.asset("video", isVideo: true)
        let shot = Fixture.asset("shot", isScreenshot: true)
        let live = Fixture.asset("live", isLivePhoto: true)

        var photos = CurationOptions()
        photos.media = .photos
        #expect(LibraryQuery.passes(photo, options: photos))
        #expect(LibraryQuery.passes(video, options: photos) == false)
        #expect(LibraryQuery.passes(shot, options: photos) == false)

        var videos = CurationOptions()
        videos.media = .videos
        #expect(LibraryQuery.passes(video, options: videos))
        #expect(LibraryQuery.passes(photo, options: videos) == false)

        var livePhotos = CurationOptions()
        livePhotos.media = .livePhotos
        #expect(LibraryQuery.passes(live, options: livePhotos))
        #expect(LibraryQuery.passes(photo, options: livePhotos) == false)

        // The screenshots section shows screenshots without needing the include switch, since
        // asking for them is the whole point of being there.
        var screenshots = CurationOptions()
        screenshots.media = .screenshots
        #expect(LibraryQuery.passes(shot, options: screenshots))
        #expect(LibraryQuery.passes(photo, options: screenshots) == false)
    }
}

/// The curator is allowed to throw frames away, which makes its safeguards the important part:
/// a memory that has been curated down to nothing is worse than an uncurated one.
struct CuratorTests {

    private func assets(_ count: Int, configure: (AssetRecord, Int) -> Void = { _, _ in }) -> [AssetRecord] {
        (0..<count).map { index in
            let record = Fixture.asset("asset-\(index)",
                                       at: Fixture.date(2024, 6, 15, 10)
                                           .addingTimeInterval(Double(index) * 60))
            configure(record, index)
            return record
        }
    }

    @Test("Pure mode changes nothing at all")
    func pureModeIsUntouched() {
        let input = assets(10) { record, _ in
            record.memoryScore = 0
            record.isBestInSimilarityCluster = false
            record.isUtilityImage = true
        }

        var options = CurationOptions()
        options.mode = .pure
        let output = Curator.curate(input, options: options)

        #expect(output.map(\.localIdentifier) == input.map(\.localIdentifier))
    }

    @Test("A handful of frames is left alone — there is nothing there to curate")
    func smallSetsAreUntouched() {
        let input = assets(3) { record, _ in record.memoryScore = 0 }
        #expect(Curator.curate(input, options: CurationOptions()).count == 3)
    }

    @Test("Smart curation drops the weak frames when enough strong ones remain")
    func weakFramesAreDropped() {
        let input = assets(12) { record, index in
            record.memoryScore = index < 8 ? 0.9 : 0.1
        }
        let output = Curator.curate(input, options: CurationOptions())

        #expect(output.count == 8)
        #expect(output.allSatisfy({ $0.memoryScore >= Curator.weakThreshold }))
    }

    @Test("Smart curation keeps only the elected frame of each similarity group")
    func onlyElectedFramesSurvive() {
        let input = assets(12) { record, index in
            record.isBestInSimilarityCluster = index % 3 == 0
        }
        let output = Curator.curate(input, options: CurationOptions())

        #expect(output.count == 4)
        #expect(output.allSatisfy(\.isBestInSimilarityCluster))
    }

    @Test("No burst is allowed to become the whole memory")
    func oneEventCannotDominate() {
        let event = UUID()
        let input = assets(20) { record, _ in record.eventClusterID = event }
        let output = Curator.curate(input, options: CurationOptions())

        #expect(!output.isEmpty)
        #expect(output.count < input.count)
        #expect(Double(output.count) <= Double(input.count) * Curator.maxShareOfOneCluster + 1)
    }

    @Test("A clip is kept even when its score would have buried it")
    func videoIsReinstated() {
        let stills = assets(12) { record, _ in record.memoryScore = 0.9 }
        let clip = Fixture.asset("clip", at: Fixture.date(2024, 6, 15, 11), score: 0.05, isVideo: true)

        let output = Curator.curate(stills + [clip], options: CurationOptions())
        #expect(output.contains(where: { $0.isVideo }))
    }

    @Test("Curation never returns nothing when it was given something")
    func neverEmptiesTheMemory() {
        // This is the safeguard the whole file exists for. Each case below is material that
        // every filter in `curate` would reject outright; a screen with something imperfect on
        // it beats a screen with nothing on it every time.
        let noneElected = assets(10) { record, _ in record.isBestInSimilarityCluster = false }
        #expect(!Curator.curate(noneElected, options: CurationOptions()).isEmpty)

        let allWeak = assets(10) { record, _ in record.memoryScore = 0 }
        #expect(!Curator.curate(allWeak, options: CurationOptions()).isEmpty)

        let allSavedImages = assets(10) { record, _ in record.isUtilityImage = true }
        #expect(!Curator.curate(allSavedImages, options: CurationOptions()).isEmpty)

        // One survivor of the similarity pass, and a weak one at that.
        let oneSurvivor = assets(10) { record, index in
            record.memoryScore = 0.1
            record.isBestInSimilarityCluster = index == 0
        }
        #expect(!Curator.curate(oneSurvivor, options: CurationOptions()).isEmpty)

        // And all of it at once.
        let hopeless = assets(10) { record, _ in
            record.memoryScore = 0
            record.isBestInSimilarityCluster = false
            record.isUtilityImage = true
            record.eventClusterID = UUID()
        }
        #expect(!Curator.curate(hopeless, options: CurationOptions()).isEmpty)

        // Right at the edge of the size guard, where the safeguards actually run.
        let four = assets(4) { record, _ in
            record.memoryScore = 0
            record.isBestInSimilarityCluster = false
            record.isUtilityImage = true
        }
        #expect(!Curator.curate(four, options: CurationOptions()).isEmpty)
    }

    @Test("Curated output comes back in the order it happened")
    func outputIsChronological() {
        let input = assets(12) { record, _ in record.memoryScore = 0.9 }
        let dates = Curator.curate(input, options: CurationOptions()).map(\.creationDate)

        #expect(dates == dates.sorted())
    }
}
