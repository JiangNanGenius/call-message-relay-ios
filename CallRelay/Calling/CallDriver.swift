import Foundation

/// The single call-control surface the UI uses. Two implementations exist:
/// ``LiveCallDriver`` (real CallKit + gateway + WebRTC) and ``DemoCallDriver``
/// (in-memory, no CallKit/network). Both expose exactly one active call.
@MainActor
protocol CallDriver: AnyObject {
    /// Fires with the current call, or nil when there is no active call.
    var onUpdate: ((ActiveCallViewState?) -> Void)? { get set }
    var onQuality: ((MediaQuality) -> Void)? { get set }
    /// Fires when the active call ended, carrying the gateway call id.
    var onEnded: ((String) -> Void)? { get set }

    /// Places an outgoing call. `lineId` is the line chosen for THIS call; nil
    /// uses the driver's configured persistent default. A temporary choice
    /// never changes the default.
    func dial(peer: String, lineId: String?)
    /// VoIP push path: report to CallKit and bind the gateway call id.
    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async
    /// Event/REST path for an incoming call not announced by push.
    func reportIncomingFromEvent(_ call: CallRecord) async
    /// Foreground: answer the currently ringing call through CallKit/demo.
    func answerCurrent()
    /// End a system call whose gateway state is already terminal.
    func endCall(gatewayId: String) async
    func hangup()
    func playDTMF(_ digit: String)
    func setMuted(_ muted: Bool)
    func setSpeaker(_ enabled: Bool)
    func reset()

    // MARK: Unified gateway multi-call/conference surface
    /// Current active (unheld) call, when any.
    var activeCallRecord: CallRecord? { get }
    /// Calls answered on this device and currently held.
    var heldCallRecords: [CallRecord] { get }
    /// Non-nil while this device hosts a merged conference.
    var conferenceRecord: ConferenceRecord? { get }
    /// Default line used for outgoing calls/legs.
    func setDefaultLineId(_ lineId: String?)
    func holdActive()
    func resume(callId: String)
    /// Merge the active call and held calls (2-3 external legs) into a conference.
    func mergeHeldCalls()
    func endConferenceLeg(callId: String)
    func holdConferenceLeg(callId: String, held: Bool)
    func playConferenceDTMF(_ digit: String, callId: String?)
    func splitConference(callId: String)
}

extension CallDriver {
    var activeCallRecord: CallRecord? { nil }
    var heldCallRecords: [CallRecord] { [] }
    var conferenceRecord: ConferenceRecord? { nil }
    func setDefaultLineId(_ lineId: String?) {}
    func holdActive() {}
    func resume(callId: String) {}
    func mergeHeldCalls() {}
    func endConferenceLeg(callId: String) {}
    func holdConferenceLeg(callId: String, held: Bool) {}
    func playConferenceDTMF(_ digit: String, callId: String?) {}
    func splitConference(callId: String) {}
}
