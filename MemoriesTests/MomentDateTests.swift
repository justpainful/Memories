import Foundation
import Testing
@testable import Memories

/// The date an asset is filed under.
///
/// Photos records when a file entered *your library*, which for anything saved from another
/// app is the day you saved it. `momentDate` is the corrected answer, and it is stored rather
/// than computed for one reason: a computed property cannot appear in a SwiftData predicate
/// or sort, so a correction that only existed in Swift would have changed the label on the
/// viewer while On This Day, Timeline and Calendar carried on using the wrong day.
struct MomentDateTests {

    private let saved = Fixture.date(2026, 8, 7, 14)
    private let recorded = Fixture.date(2023, 6, 1, 19)

    @Test("Without a recovered date, the moment is the library's own date")
    func defaultsToLibraryDate() {
        let record = Fixture.asset("a", at: saved)
        #expect(record.momentDate == saved)
        #expect(record.hasCorrectedDate == false)
    }

    @Test("A recovered date becomes the moment once it is applied")
    func recoveredDateWins() {
        let record = Fixture.asset("a", at: saved)
        record.capturedDate = recorded
        record.refreshMomentDate()

        #expect(record.momentDate == recorded)
        #expect(record.creationDate == saved, "the library's own date is kept, not overwritten")
        #expect(record.hasCorrectedDate)
    }

    @Test("Clearing the recovered date puts the moment back")
    func clearingReverts() {
        let record = Fixture.asset("a", at: saved)
        record.capturedDate = recorded
        record.refreshMomentDate()

        record.capturedDate = nil
        record.refreshMomentDate()
        #expect(record.momentDate == saved)
        #expect(record.hasCorrectedDate == false)
    }

    @Test("Dates that agree within a day are not reported as corrected")
    func smallDisagreementIsNotACorrection() {
        let record = Fixture.asset("a", at: saved)
        record.capturedDate = saved.addingTimeInterval(-3600)
        record.refreshMomentDate()

        // The moment still follows the recovered value; only the *notice* to the user is
        // suppressed, because an hour's difference explains nothing worth explaining.
        #expect(record.momentDate == record.capturedDate)
        #expect(record.hasCorrectedDate == false)
    }
}
