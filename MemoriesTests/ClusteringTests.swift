import Foundation
import Testing
@testable import Memories

/// Similarity clustering decides which frames stop competing for room inside a memory. Grouping
/// too eagerly hides photographs the user took on purpose; grouping too timidly fills a memory
/// with fourteen versions of the same face.
struct SimilarityClusteringTests {

    private let start = Fixture.date(2024, 6, 15, 14)

    @Test("Frames that look alike and were taken seconds apart become one group")
    func lookalikesGroup() {
        let inputs = [
            Fixture.clusterInput("a", at: start, vector: [1, 0, 0, 0]),
            Fixture.clusterInput("b", at: start.addingTimeInterval(2), vector: [1, 0, 0, 0]),
            Fixture.clusterInput("c", at: start.addingTimeInterval(4), vector: [0.99, 0.01, 0, 0]),
        ]

        let groups = SimilarityClustering.cluster(inputs)
        #expect(groups.count == 1)
        #expect(groups.first?.count == 3)
    }

    @Test("Frames that look nothing alike stay apart")
    func differentFramesDoNotGroup() {
        let inputs = [
            Fixture.clusterInput("a", at: start, vector: [1, 0, 0, 0]),
            Fixture.clusterInput("b", at: start.addingTimeInterval(2), vector: [0, 1, 0, 0]),
        ]
        #expect(SimilarityClustering.cluster(inputs).count == 2)
    }

    @Test("A shared burst identifier groups frames whatever their feature vectors say")
    func burstOutranksAppearance() {
        // The camera already told us this was one press, so the vectors are not consulted —
        // and here they disagree completely, which is the point.
        let onePress = [
            Fixture.clusterInput("a", at: start, burst: "burst-1", vector: [1, 0, 0, 0]),
            Fixture.clusterInput("b", at: start.addingTimeInterval(1), burst: "burst-1", vector: [0, 1, 0, 0]),
        ]
        let grouped = SimilarityClustering.cluster(onePress)
        #expect(grouped.count == 1)
        #expect(grouped.first?.count == 2)

        // Two separate presses that happen to look identical still group, on appearance.
        let separatePresses = [
            Fixture.clusterInput("a", at: start, burst: "burst-1", vector: [1, 0, 0, 0]),
            Fixture.clusterInput("b", at: start.addingTimeInterval(1), burst: "burst-2", vector: [1, 0, 0, 0]),
        ]
        #expect(SimilarityClustering.cluster(separatePresses).count == 1)
    }

    @Test("Frames outside the comparison window are never one shot, however alike")
    func timeWindowIsRespected() {
        let identical = [
            Fixture.clusterInput("a", at: start, vector: [1, 0, 0, 0]),
            Fixture.clusterInput("b", at: start.addingTimeInterval(SimilarityClustering.window + 1),
                                 vector: [1, 0, 0, 0]),
        ]
        #expect(SimilarityClustering.cluster(identical).count == 2)

        // A burst identifier does not buy its way past the window either.
        let staleBurst = [
            Fixture.clusterInput("a", at: start, burst: "burst-1", vector: [1, 0, 0, 0]),
            Fixture.clusterInput("b", at: start.addingTimeInterval(SimilarityClustering.window + 1),
                                 burst: "burst-1", vector: [1, 0, 0, 0]),
        ]
        #expect(SimilarityClustering.cluster(staleBurst).count == 2)
    }

    @Test("The best shot of a group is the highest scoring frame")
    func bestShotPicksTheBest() throws {
        let group = [
            Fixture.clusterInput("weak", at: start, score: 0.4),
            Fixture.clusterInput("strong", at: start.addingTimeInterval(1), score: 0.9),
            Fixture.clusterInput("middling", at: start.addingTimeInterval(2), score: 0.7),
        ]
        let best = try #require(SimilarityClustering.bestShot(in: group))
        #expect(best.identifier == "strong")
    }

    @Test("A tie on score goes to the earlier frame, the one that was actually aimed")
    func bestShotBreaksTiesEarly() throws {
        let group = [
            Fixture.clusterInput("later", at: start.addingTimeInterval(3), score: 0.8),
            Fixture.clusterInput("earlier", at: start, score: 0.8),
        ]
        let best = try #require(SimilarityClustering.bestShot(in: group))
        #expect(best.identifier == "earlier")
    }

    @Test("An empty group elects nobody")
    func bestShotOfNothing() {
        #expect(SimilarityClustering.bestShot(in: []) == nil)
    }
}

/// Event clustering turns a stream of timestamps into occasions. It is what decides whether the
/// dinner and the walk home are one memory or two.
struct EventClusteringTests {

    private let morning = Fixture.date(2024, 6, 15, 10)

    private func run(_ prefix: String,
                     count: Int,
                     from start: Date,
                     everyMinutes minutes: Double,
                     latitude: Double? = nil,
                     longitude: Double? = nil,
                     score: Double = 0.5) -> [ClusterInput] {
        (0..<count).map { index in
            Fixture.clusterInput("\(prefix)-\(index)",
                                 at: start.addingTimeInterval(Double(index) * minutes * 60),
                                 latitude: latitude,
                                 longitude: longitude,
                                 score: score)
        }
    }

    @Test("A pause longer than the gap threshold ends the occasion")
    func gapSplitsEvents() {
        let first = run("morning", count: 4, from: morning, everyMinutes: 5)
        let second = run("later", count: 4,
                         from: morning.addingTimeInterval(EventClustering.gapThreshold + 3_600),
                         everyMinutes: 5)

        let events = EventClustering.cluster(first + second)
        #expect(events.count == 2)
        #expect(events.allSatisfy({ $0.count == 4 }))
    }

    @Test("A lull inside an occasion does not end it")
    func shortPausesKeepOneEvent() {
        // Half an hour between courses is well inside the threshold.
        let dinner = run("dinner", count: 6, from: morning, everyMinutes: 30)
        let events = EventClustering.cluster(dinner)
        #expect(events.count == 1)
        #expect(events.first?.count == 6)
    }

    @Test("Moving a long way ends the occasion whatever the clock says")
    func distanceSplitsEvents() {
        let here = run("london", count: 4, from: morning, everyMinutes: 2,
                       latitude: 51.5074, longitude: -0.1278)
        let there = run("paris", count: 4, from: morning.addingTimeInterval(8 * 60), everyMinutes: 2,
                        latitude: 48.8566, longitude: 2.3522)

        // Two minutes apart on the clock, some 340 km apart on the ground.
        let events = EventClustering.cluster(here + there)
        #expect(events.count == 2)
        #expect(events.allSatisfy({ $0.count == 4 }))
    }

    @Test("A handful of frames is not an occasion")
    func shortRunsAreDropped() {
        let few = run("few", count: EventClustering.minimumCount - 1, from: morning, everyMinutes: 3)
        #expect(EventClustering.cluster(few).isEmpty)
        #expect(EventClustering.cluster([]).isEmpty)

        let enough = run("enough", count: EventClustering.minimumCount, from: morning, everyMinutes: 3)
        #expect(EventClustering.cluster(enough).count == 1)
    }

    @Test("A night that rolls past midnight stays one occasion")
    func midnightDoesNotSplitAnEvent() {
        let night = run("night", count: 6, from: Fixture.date(2024, 6, 15, 23, 30), everyMinutes: 10)
        let events = EventClustering.cluster(night)
        #expect(events.count == 1)
        #expect(events.first?.count == 6)

        // The source reaches for `Calendar.current` here, to end an event at a day boundary when
        // there is "also a real pause". That clause cannot fire: it is only reached once the
        // 45-minute gap rule has declined to break, and it then asks for a gap of more than six
        // hours. Which is why this result is the same in every time zone.
    }

    @Test("Significance stays inside 0...1, however implausible the occasion")
    func significanceIsBounded() {
        let frantic = (0..<200).map {
            Fixture.clusterInput("f\($0)", at: morning.addingTimeInterval(Double($0) * 0.1),
                                 isVideo: true, score: 1)
        }
        let high = EventClustering.significance(of: frantic)
        #expect(high >= 0)
        #expect(high <= 1)

        let sparse = run("sparse", count: 4, from: morning, everyMinutes: 240, score: 0)
        let low = EventClustering.significance(of: sparse)
        #expect(low >= 0)
        #expect(low <= 1)
    }

    @Test("A run too short to be an occasion carries no significance at all")
    func significanceOfShortRuns() {
        let few = run("few", count: EventClustering.minimumCount - 1, from: morning, everyMinutes: 5)
        #expect(EventClustering.significance(of: few) == 0)
        #expect(EventClustering.significance(of: []) == 0)
    }

    @Test("Better frames, and a clip among them, make an occasion stand out more")
    func significanceRewardsQualityAndVariety() {
        let dull = run("dull", count: 10, from: morning, everyMinutes: 2, score: 0.2)
        let good = run("good", count: 10, from: morning, everyMinutes: 2, score: 0.9)
        #expect(EventClustering.significance(of: good) > EventClustering.significance(of: dull))

        var withClip = good
        withClip[0].isVideo = true
        #expect(EventClustering.significance(of: withClip) > EventClustering.significance(of: good))
    }

    @Test("An occasion is titled from the hour it began")
    func titlesReadFromTheClock() throws {
        // Frames are built with `Calendar.current` on purpose: `title` reads the hour back with
        // the same calendar, so the hour asserted here is the hour it sees, wherever this runs.
        // Only the weekday name is regional, so the assertions below never look at it.
        let lateNight = try EventClustering.title(for: [frame(atHour: 2)])
        let morningTitle = try EventClustering.title(for: [frame(atHour: 8)])
        let afternoon = try EventClustering.title(for: [frame(atHour: 13)])
        let evening = try EventClustering.title(for: [frame(atHour: 18)])
        let night = try EventClustering.title(for: [frame(atHour: 22)])

        #expect(lateNight == "A late night")
        #expect(morningTitle.hasSuffix(" morning"))
        #expect(afternoon.hasSuffix(" afternoon"))
        #expect(evening.hasSuffix(" evening"))
        #expect(night.hasSuffix(" night"))
        #expect(night != lateNight)

        #expect(EventClustering.title(for: []) == "An occasion")
    }

    /// 15 June 2024 at a given hour, in whatever zone this is running in. Mid-June is clear of
    /// every daylight-saving transition, so the hour asked for is always an hour that exists.
    private func frame(atHour hour: Int) throws -> ClusterInput {
        var components = DateComponents()
        components.year = 2024
        components.month = 6
        components.day = 15
        components.hour = hour
        let date = try #require(Calendar.current.date(from: components))
        return Fixture.clusterInput("hour-\(hour)", at: date)
    }
}
