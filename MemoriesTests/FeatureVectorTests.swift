import Foundation
import Testing
@testable import Memories

/// Everything downstream of `similarity(to:)` is a threshold comparison, so the two ends of its
/// range and its behaviour on nonsense input are the whole contract. It is also the one piece of
/// this app that reads bytes back off disk and trusts them.
struct FeatureVectorTests {

    @Test("A vector is identical to itself and shares nothing with an orthogonal one")
    func similarityEndpoints() {
        let vector = FeatureVector(values: [0.4, 0.1, 0.9, 0.2])
        #expect(Fixture.isClose(vector.similarity(to: vector), 1))

        let x = FeatureVector(values: [1, 0, 0, 0])
        let y = FeatureVector(values: [0, 1, 0, 0])
        #expect(x.similarity(to: y) == 0)

        // Scale carries no information — cosine only cares about direction.
        let scaled = FeatureVector(values: [0.8, 0.2, 1.8, 0.4])
        #expect(Fixture.isClose(vector.similarity(to: scaled), 1))
    }

    @Test("Nothing sensible to compare means no similarity, not a crash")
    func degenerateComparisons() {
        let empty = FeatureVector(values: [])
        let vector = FeatureVector(values: [1, 2, 3])
        let shorter = FeatureVector(values: [1, 2])
        let zeroes = FeatureVector(values: [0, 0, 0])

        #expect(empty.isEmpty)
        #expect(empty.similarity(to: empty) == 0)
        #expect(empty.similarity(to: vector) == 0)
        #expect(vector.similarity(to: empty) == 0)
        #expect(vector.similarity(to: shorter) == 0)   // lengths from two different Vision revisions
        #expect(shorter.similarity(to: vector) == 0)
        #expect(vector.similarity(to: zeroes) == 0)    // no magnitude to point anywhere
    }

    @Test("A vector survives the trip through storage")
    func roundTripThroughData() throws {
        // Vectors are written at half precision to keep the index small, so a round trip is
        // close rather than exact — which is why these are tolerances and not equalities.
        let original = FeatureVector(values: [0.42, 0.13, 0.87, 0.05, 0.61, 0.29])
        let other = FeatureVector(values: [0.40, 0.20, 0.80, 0.10, 0.55, 0.35])

        let restored = try #require(FeatureVector(data: original.data))
        #expect(restored.values.count == original.values.count)
        #expect(Fixture.isClose(original.similarity(to: restored), 1, tolerance: 1e-3))

        // What actually has to hold: a comparison made after storage answers the same question
        // as the one made before it, well inside the 0.92 threshold anything is judged against.
        let restoredOther = try #require(FeatureVector(data: other.data))
        #expect(Fixture.isClose(original.similarity(to: other),
                                restored.similarity(to: restoredOther),
                                tolerance: 5e-3))
    }

    @Test("Storage that could not have come from a vector is rejected")
    func rejectsUnusableData() {
        #expect(FeatureVector(data: Data()) == nil)
        #expect(FeatureVector(data: Data([0x01])) == nil)          // an odd number of bytes
        #expect(FeatureVector(data: Data([0x01, 0x02, 0x03])) == nil)

        // An empty vector has no representation to come back from, which is fine: an empty
        // print is never worth writing, and every caller checks `isEmpty` before comparing.
        #expect(FeatureVector(data: FeatureVector(values: []).data) == nil)
    }
}
