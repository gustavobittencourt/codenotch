
import XCTest
@testable import Codenotch

/// Session monitors scan every tick for a while after someone looked, and
/// at the resting interval otherwise.
@MainActor
final class ActivityPaceTests: XCTestCase {
    func testScansAtTheRestingIntervalUntilSomeoneLooks() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        ActivityPace.looked(at: t0)
        let later = t0.addingTimeInterval(ActivityPace.lookWindow + 1)
        XCTAssertFalse(ActivityPace.isDue(lastScan: later.addingTimeInterval(-2), now: later))
        XCTAssertTrue(ActivityPace.isDue(lastScan: later.addingTimeInterval(-ActivityPace.restingInterval), now: later))

        let looking = t0.addingTimeInterval(5)
        XCTAssertTrue(ActivityPace.isDue(lastScan: looking.addingTimeInterval(-2), now: looking))
    }
}

