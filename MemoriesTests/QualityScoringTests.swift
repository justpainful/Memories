import Foundation
import Testing
@testable import Memories

/// The Memory Quality Score is a blend of a dozen weighted terms, and those weights will be
/// retuned. So nothing here asserts a number: these tests pin the relationships that must
/// survive any retuning — the bounds, the direction of each signal, and the rule that a
/// measurement Vision could not make must count for nothing at all.
struct QualityScoringTests {

    /// An unremarkable frame: real resolution, no flags, nothing measured.
    private func baseline() -> QualityInputs {
        var input = QualityInputs()
        input.pixelWidth = 4032
        input.pixelHeight = 3024
        return input
    }

    @Test("The score always lands in 0...1, however extreme the inputs")
    func scoreIsBounded() {
        var best = QualityInputs()
        best.aesthetics = 1
        best.sharpness = 1
        best.composition = 1
        best.subjectProminence = 1
        best.faceCount = 2
        best.bestFaceQuality = 1
        best.isFavorite = true
        best.averageColor = 0x80_80_80
        best.pixelWidth = 8000
        best.pixelHeight = 6000
        // Every term pulling the same way overshoots 1, so this proves the clamp, not the sum.
        #expect(QualityScorer.score(best) == 1)

        var worst = QualityInputs()
        worst.aesthetics = -1
        worst.sharpness = 0
        worst.composition = 0
        worst.subjectProminence = 0
        worst.isScreenshot = true
        worst.isUtility = true
        worst.duplicateCount = 50
        worst.burstPosition = 50
        worst.averageColor = 0x01_01_01
        worst.pixelWidth = 100
        worst.pixelHeight = 100
        #expect(QualityScorer.score(worst) == 0)

        // And values well outside the documented ranges still cannot escape.
        var absurd = QualityInputs()
        absurd.aesthetics = 50
        absurd.sharpness = -50
        absurd.composition = 90
        absurd.subjectProminence = -90
        absurd.pixelWidth = 100_000
        absurd.pixelHeight = 100_000
        let score = QualityScorer.score(absurd)
        #expect(score >= 0)
        #expect(score <= 1)
    }

    @Test("A screenshot scores below the identical frame that isn't one")
    func screenshotsScoreLower() {
        var plain = baseline()
        plain.aesthetics = 0.2
        var shot = plain
        shot.isScreenshot = true

        #expect(QualityScorer.score(shot) < QualityScorer.score(plain))
    }

    @Test("A favourite outranks the identical frame the user never marked")
    func favouritesScoreHigher() {
        let plain = baseline()
        var loved = plain
        loved.isFavorite = true

        #expect(QualityScorer.score(loved) > QualityScorer.score(plain))
    }

    @Test("Duplicates and later burst frames both drag a frame down")
    func duplicatesAndBurstPositionPenalise() {
        let single = baseline()
        var few = single
        few.duplicateCount = 2
        var many = single
        many.duplicateCount = 6

        #expect(QualityScorer.score(few) < QualityScorer.score(single))
        #expect(QualityScorer.score(many) < QualityScorer.score(few))

        let first = baseline()
        var second = baseline()
        second.burstPosition = 1
        var late = baseline()
        late.burstPosition = 3

        #expect(QualityScorer.score(second) < QualityScorer.score(first))
        #expect(QualityScorer.score(late) < QualityScorer.score(second))
    }

    @Test("A measurement Vision could not make counts for nothing")
    func nilInputsAreNeutral() {
        let unmeasured = baseline()

        // Each optional term has a value at which it contributes exactly zero. Passing that
        // value must score the same as passing nothing — otherwise an unanalyzed frame is
        // being quietly rewarded or punished for the absence of a reading.
        var neutral = baseline()
        neutral.aesthetics = 0            // the midpoint of -1...1
        neutral.sharpness = 0.45
        neutral.composition = 0.5
        neutral.subjectProminence = 0.14  // four tenths of the 0.35 cap

        #expect(Fixture.isClose(QualityScorer.score(unmeasured), QualityScorer.score(neutral)))

        // One at a time, so a compensating pair of errors cannot hide inside the total.
        var aestheticsOnly = baseline()
        aestheticsOnly.aesthetics = 0
        #expect(Fixture.isClose(QualityScorer.score(aestheticsOnly), QualityScorer.score(unmeasured)))

        var sharpnessOnly = baseline()
        sharpnessOnly.sharpness = 0.45
        #expect(Fixture.isClose(QualityScorer.score(sharpnessOnly), QualityScorer.score(unmeasured)))

        var compositionOnly = baseline()
        compositionOnly.composition = 0.5
        #expect(Fixture.isClose(QualityScorer.score(compositionOnly), QualityScorer.score(unmeasured)))

        var prominenceOnly = baseline()
        prominenceOnly.subjectProminence = 0.14
        #expect(Fixture.isClose(QualityScorer.score(prominenceOnly), QualityScorer.score(unmeasured)))
    }

    @Test("Faces counted without a quality reading still score, and still score sanely")
    func facesWithoutAQualityReading() {
        var faces = baseline()
        faces.faceCount = 3
        faces.bestFaceQuality = nil

        let score = QualityScorer.score(faces)
        #expect(score >= 0)
        #expect(score <= 1)
        // A face is a reason on its own, even when its capture quality is unknown.
        #expect(score > QualityScorer.score(baseline()))
    }

    @Test("A well-captured face lifts a frame, a poorly captured one does not")
    func faceQualityMoves() {
        var poor = baseline()
        poor.faceCount = 1
        poor.bestFaceQuality = 0

        var good = baseline()
        good.faceCount = 1
        good.bestFaceQuality = 1

        #expect(QualityScorer.score(good) > QualityScorer.score(poor))
    }
}
