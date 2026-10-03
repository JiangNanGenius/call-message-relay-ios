import XCTest
@testable import CallRelay

/// Exact-once action completion policy shared by the LCK adapter. The system
/// framework ships no simulator slice, so the claim/fail/reset/timeout
/// semantics live in the LCK-independent ``LiveCommunicationActionCore`` and
/// are tested directly here; the adapter is a thin mapping layer.
@MainActor
final class LiveCommunicationActionCoreTests: XCTestCase {
    typealias Core = LiveCommunicationActionCore<Int>
    typealias Token = LiveCommunicationActionCore<Int>.Token

    private func makeCore() -> Core { LiveCommunicationActionCore<Int>() }

    func testClaimIsExactOnceAndCompletesAtMostOnce() {
        let core = makeCore()
        let token = Token(id: 1)
        XCTAssertEqual(core.adjudicate(token, hasDirector: true), .proceed)
        // The SAME action delivered twice is ignored — never double fulfill.
        XCTAssertEqual(core.adjudicate(token, hasDirector: true), .ignore)

        let gen = core.deliveryGeneration()
        XCTAssertTrue(core.fulfill(token, deliveredIn: gen))
        // A late async result after fulfill cannot fail it.
        XCTAssertFalse(core.fail(token, deliveredIn: gen))
        XCTAssertEqual(token.fulfillCount, 1)
        XCTAssertEqual(token.failCount, 0)
    }

    func testMissingDirectorFailsExactlyOnce() {
        let core = makeCore()
        let token = Token(id: 2)
        XCTAssertEqual(core.adjudicate(token, hasDirector: false), .fail)
        XCTAssertEqual(token.failCount, 1, "an action with no director fails once")
        // Re-delivery of the failed action does nothing.
        XCTAssertEqual(core.adjudicate(token, hasDirector: false), .ignore)
        XCTAssertEqual(token.failCount, 1)
    }

    func testDirectorArrivingLaterDoesNotCompleteTheFailedAction() {
        let core = makeCore()
        let token = Token(id: 3)
        XCTAssertEqual(core.adjudicate(token, hasDirector: false), .fail)
        // Even if a director is wired afterward, the action is sealed.
        XCTAssertEqual(core.adjudicate(token, hasDirector: true), .ignore)
    }

    func testResetFencesLateAsyncCompletions() {
        let core = makeCore()
        let token = Token(id: 4)
        XCTAssertEqual(core.adjudicate(token, hasDirector: true), .proceed)
        let gen = core.deliveryGeneration()

        // System reset while the gateway work is in flight.
        core.reset()
        XCTAssertEqual(core.deliveryGeneration(), gen &+ 1)

        // The awaited answer/hangup returns: the OLD generation must not
        // fulfill the action.
        XCTAssertFalse(core.fulfill(token, deliveredIn: gen))
        XCTAssertFalse(core.fail(token, deliveredIn: gen))
        XCTAssertEqual(token.fulfillCount, 0)
        XCTAssertEqual(token.failCount, 0)
    }

    func testTimedOutActionCanNeverComplete() {
        let core = makeCore()
        let token = Token(id: 5)
        XCTAssertEqual(core.adjudicate(token, hasDirector: true), .proceed)
        let gen = core.deliveryGeneration()
        core.markTimedOut(token)
        XCTAssertFalse(core.completable(token, deliveredIn: gen))
        XCTAssertFalse(core.fulfill(token, deliveredIn: gen))
        XCTAssertFalse(core.fail(token, deliveredIn: gen))
        XCTAssertEqual(token.fulfillCount, 0)
    }

    func testStrongPinsPreventIdentifierReuseAndStayBoundedAfterReset() {
        final class Sentinel {}
        let core = makeCore()
        let token = Token(id: 6, pin: Sentinel())
        _ = core.adjudicate(token, hasDirector: true)
        XCTAssertEqual(core.retainedPinCount, 1, "claimed actions are pinned strongly")
        let gen = core.deliveryGeneration()
        _ = core.fulfill(token, deliveredIn: gen)
        // The next claim purges finalized pins so the map cannot grow.
        let token2 = Token(id: 7, pin: Sentinel())
        _ = core.adjudicate(token2, hasDirector: true)
        XCTAssertEqual(core.retainedPinCount, 1)
        // Reset releases everything.
        core.reset()
        XCTAssertEqual(core.retainedPinCount, 0)
    }

    func testTimedOutPinsSurviveUntilReset() {
        final class Sentinel {}
        let core = makeCore()
        let token = Token(id: 8, pin: Sentinel())
        core.markTimedOut(token)
        XCTAssertEqual(core.timedOutCount, 1)
        XCTAssertEqual(core.retainedPinCount, 1)
        core.reset()
        XCTAssertEqual(core.timedOutCount, 0)
        XCTAssertEqual(core.retainedPinCount, 0)
    }

    func testIndependentActionsCompleteIndependently() {
        let core = makeCore()
        let a = Token(id: 10)
        let b = Token(id: 11)
        XCTAssertEqual(core.adjudicate(a, hasDirector: true), .proceed)
        XCTAssertEqual(core.adjudicate(b, hasDirector: true), .proceed)
        let gen = core.deliveryGeneration()
        XCTAssertTrue(core.fulfill(a, deliveredIn: gen))
        // B is unaffected by A completing.
        XCTAssertTrue(core.completable(b, deliveredIn: gen))
        XCTAssertTrue(core.fulfill(b, deliveredIn: gen))
        XCTAssertEqual(a.fulfillCount, 1)
        XCTAssertEqual(b.fulfillCount, 1)
    }
}
