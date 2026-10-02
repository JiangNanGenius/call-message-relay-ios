import XCTest
@testable import CallRelay

@MainActor
final class VoicemailPlaybackTests: XCTestCase {
    private final class FakePlayer: VoicemailAudioPlaying {
        var duration: TimeInterval = 5
        var playResult = true
        var onCompletion: (() -> Void)?
        private(set) var playCount = 0
        private(set) var stopCount = 0
        func play() -> Bool { playCount += 1; return playResult }
        func stop() { stopCount += 1 }
        /// Simulates AVAudioPlayer's natural end-of-clip delegate callback.
        func finish() { onCompletion?() }
    }

    private final class FakeSession: VoicemailAudioSessionControlling {
        var activationError: Error?
        private(set) var activateCount = 0
        private(set) var deactivateCount = 0
        func activate() throws {
            activateCount += 1
            if let activationError { throw activationError }
        }
        func deactivate() { deactivateCount += 1 }
    }

    private struct FakeError: Error {}

    private func makeController(session: FakeSession, player: FakePlayer) -> VoicemailPlaybackController {
        VoicemailPlaybackController(session: session, makePlayer: { _ in player })
    }

    func testPlaybackRefusedWhileCallActive() {
        let session = FakeSession()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        controller.isCallActive = { true }
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        XCTAssertNil(controller.playingId, "playback must not start during a call")
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(session.activateCount, 0, "shared CallKit audio session must not be overridden")
        XCTAssertEqual(session.deactivateCount, 0, "a live call's session must never be deactivated")
        XCTAssertNotNil(controller.errorMessage)
    }

    func testBeginRequestInvalidatesPreviousFetch() {
        let controller = makeController(session: FakeSession(), player: FakePlayer())
        let first = controller.beginRequest("vm_old")
        let second = controller.beginRequest("vm_new")
        XCTAssertFalse(controller.isCurrent(first), "stale fetch token must be invalid after a new request")
        XCTAssertTrue(controller.isCurrent(second))
        controller.play(id: "vm_new", data: Data())
        XCTAssertEqual(controller.playingId, "vm_new")
    }

    func testOverlappingPlayStopsPreviousClip() {
        let session = FakeSession()
        let first = FakePlayer()
        let second = FakePlayer()
        var built = 0
        let controller = VoicemailPlaybackController(session: session, makePlayer: { _ in
            built += 1
            return built == 1 ? first : second
        })
        _ = controller.beginRequest("vm_a")
        controller.play(id: "vm_a", data: Data())
        XCTAssertEqual(controller.playingId, "vm_a")
        controller.play(id: "vm_b", data: Data())
        XCTAssertEqual(controller.playingId, "vm_b")
        XCTAssertEqual(first.stopCount, 1, "previous clip must be stopped")
        XCTAssertEqual(second.playCount, 1)
    }

    func testStopDeactivatesVoicemailOwnedSessionOnlyOnce() {
        let session = FakeSession()
        let controller = makeController(session: session, player: FakePlayer())
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        XCTAssertEqual(session.activateCount, 1)
        controller.stop()
        controller.stop()
        XCTAssertEqual(session.deactivateCount, 1, "only the voicemail-owned activation is released")
        XCTAssertNil(controller.playingId)
    }

    func testCallStateChangeStopsPlaybackAndCancelsPendingFetch() {
        let session = FakeSession()
        let controller = makeController(session: session, player: FakePlayer())
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        let pending = controller.beginRequest("vm_2")
        controller.isCallActive = { true }
        controller.handleCallStateChange()
        XCTAssertNil(controller.playingId)
        XCTAssertFalse(controller.isCurrent(pending), "pending fetch must be invalidated by a call")
        XCTAssertEqual(session.deactivateCount, 1)
    }

    func testActivationFailureLeavesNoPlayerRunning() {
        let session = FakeSession()
        session.activationError = FakeError()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        XCTAssertNil(controller.playingId)
        XCTAssertEqual(player.playCount, 0)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(session.deactivateCount, 0, "a failed activation owns nothing to release")
    }

    // MARK: CallKit ownership hand-off

    func testCallHandoffClearsOwnershipWithoutDeactivatingCallSession() {
        let session = FakeSession()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(controller.playingId, "vm_1")

        // The call starts while the clip is still playing; there is deliberately
        // no intervening beginRequest/stop (the old test pre-stopped playback).
        controller.isCallActive = { true }
        controller.handleCallStateChange()
        XCTAssertNil(controller.playingId)
        XCTAssertEqual(player.stopCount, 1, "clip must stop when the call takes over")
        XCTAssertEqual(session.deactivateCount, 0, "call-owned session must not be deactivated")

        // The later disappear/stop path and repeated state changes stay inert.
        controller.stop()
        controller.handleCallStateChange()
        XCTAssertEqual(session.deactivateCount, 0, "no voicemail stop path may deactivate the live call")
        XCTAssertNil(controller.playingId)
    }

    func testStopWhileCallActiveNeverDeactivatesSession() {
        let session = FakeSession()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())

        // A call is already live but this controller was not told yet (view
        // disappearance can race the state change): stop() must still not
        // touch the shared session.
        controller.isCallActive = { true }
        controller.stop()
        XCTAssertNil(controller.playingId)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertEqual(session.deactivateCount, 0)
    }

    func testBeginRequestAndRefusedPlayDuringCallDoNotDeactivateSession() {
        let session = FakeSession()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        controller.isCallActive = { true }

        let token = controller.beginRequest("vm_2")
        XCTAssertTrue(controller.isCurrent(token))
        XCTAssertEqual(session.deactivateCount, 0, "beginRequest must not deactivate a live call")

        // Even if the fetch resolves during the call, starting playback is
        // refused without touching the live session.
        controller.play(id: "vm_2", data: Data())
        XCTAssertNil(controller.playingId)
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(session.deactivateCount, 0)
        XCTAssertNotNil(controller.errorMessage)
    }

    // MARK: Natural completion

    func testNaturalCompletionClearsPlaybackAndReleasesOwnedSession() {
        let session = FakeSession()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        XCTAssertEqual(controller.playingId, "vm_1")

        player.finish() // AVAudioPlayer reached its natural end
        XCTAssertNil(controller.playingId, "natural completion must clear the UI state")
        XCTAssertEqual(session.deactivateCount, 1, "voicemail must release only its own activation")
        XCTAssertEqual(player.stopCount, 1)

        player.finish() // duplicated late callback
        XCTAssertEqual(session.deactivateCount, 1)
        XCTAssertNil(controller.playingId)
    }

    func testNaturalCompletionDuringCallDoesNotDeactivateCallSession() {
        let session = FakeSession()
        let player = FakePlayer()
        let controller = makeController(session: session, player: player)
        _ = controller.beginRequest("vm_1")
        controller.play(id: "vm_1", data: Data())
        controller.isCallActive = { true }

        player.finish()
        XCTAssertNil(controller.playingId)
        XCTAssertEqual(session.deactivateCount, 0, "completion must not deactivate the live call")
    }

    func testStaleCompletionCannotStopNewClip() {
        let session = FakeSession()
        let first = FakePlayer()
        let second = FakePlayer()
        var built = 0
        let controller = VoicemailPlaybackController(session: session, makePlayer: { _ in
            built += 1
            return built == 1 ? first : second
        })
        _ = controller.beginRequest("vm_a")
        controller.play(id: "vm_a", data: Data())
        let stale = first.onCompletion
        XCTAssertNotNil(stale)

        controller.play(id: "vm_b", data: Data())
        XCTAssertEqual(controller.playingId, "vm_b")
        stale?()
        XCTAssertEqual(controller.playingId, "vm_b", "a finished older clip must not clear the new one")
        XCTAssertEqual(second.stopCount, 0, "a stale completion must not stop the new clip")
        XCTAssertEqual(session.deactivateCount, 0, "the session still belongs to the new clip")

        second.finish()
        XCTAssertNil(controller.playingId)
        XCTAssertEqual(session.deactivateCount, 1)
    }

    func testCompletionAfterNewRequestDoesNotTouchPendingFetch() {
        let session = FakeSession()
        let first = FakePlayer()
        let controller = makeController(session: session, player: first)
        _ = controller.beginRequest("vm_a")
        controller.play(id: "vm_a", data: Data())
        let stale = first.onCompletion
        let token = controller.beginRequest("vm_b")
        XCTAssertEqual(session.deactivateCount, 1)

        stale?() // late completion from the replaced clip
        XCTAssertTrue(controller.isCurrent(token), "stale completion must not invalidate the pending fetch")
        XCTAssertEqual(session.deactivateCount, 1, "stale completion must not release the session twice")
        XCTAssertNil(controller.playingId)
    }
}
