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

    func dial(peer: String)
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
}
