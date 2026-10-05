import Foundation

/// Whether the SYSTEM call surface (CallKit/LCK) accepted an incoming report.
/// Tracking a call inside the app is NOT system acceptance: only `.accepted`
/// means a system call/conversation exists.
enum SystemReportState: Equatable {
    /// No system report was ever attempted for this call (demo/legacy path).
    case unknown
    /// The system accepted the report and a system call exists.
    case accepted
    /// The system (or the report call) rejected it: no system UI for this call.
    case rejected
}

/// The single call-control surface the UI uses. Two implementations exist:
/// ``LiveCallDriver`` (real CallKit + gateway + WebRTC) and ``DemoCallDriver``
/// (in-memory, no CallKit/network). Both expose exactly one active call.
@MainActor
protocol CallDriver: AnyObject {
    /// Fires with the current call, or nil when there is no active call.
    var onUpdate: ((ActiveCallViewState?) -> Void)? { get set }
    var onQuality: ((MediaQuality) -> Void)? { get set }
    /// Live routing snapshot for the compact in-call route menu.
    var onRouteState: ((CallRouteState) -> Void)? { get set }
    /// A failed route selection: message + whether to offer "switch to auto".
    var onRouteNotice: ((String, Bool) -> Void)? { get set }
    /// Honest, minimal copy while audio ownership is unavailable (another
    /// app holds the session, an interruption is pending, the audio server is
    /// resetting). nil clears the notice.
    var onAudioStatus: ((String?) -> Void)? { get set }
    /// Fires when the active call ended, carrying the gateway call id.
    var onEnded: ((String) -> Void)? { get set }

    /// Places an outgoing call. `lineId` is the line chosen for THIS call; nil
    /// uses the driver's configured persistent default. A temporary choice
    /// never changes the default.
    func dial(peer: String, lineId: String?)
    /// VoIP push path: report to CallKit/LCK and bind the gateway call id.
    /// The result is observable through ``systemReportState(gatewayId:)``;
    /// the method itself stays `Void` so existing drivers/tests are unchanged.
    func reportIncomingPush(gatewayId: String, uuid: UUID, handle: String, record: CallRecord?) async
    /// Event/REST path for an incoming call not announced by push.
    func reportIncomingFromEvent(_ call: CallRecord) async
    /// System acceptance of the incoming report for this gateway call.
    /// `.unknown` means no report was attempted (or the driver has no system
    /// surface); `.rejected` means the app must not assume a system ring
    /// exists, so a repeated push may attempt the report again.
    func systemReportState(gatewayId: String) -> SystemReportState
    /// True while this gateway call is still ringing and may be (re)reported.
    /// Bounds push-driven retries so a permanently rejected call cannot loop.
    func canAttemptSystemReport(gatewayId: String) -> Bool
    /// True while the gateway call is still tracked as ringing.
    func isRinging(gatewayId: String) -> Bool
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
    /// Changes the Auto/Direct/Relay mode for the active call.
    func selectRouteMode(_ mode: MediaRouteMode)
    /// The bound gateway's persisted default route mode.
    var routeModeDefault: MediaRouteMode { get }
}

extension CallDriver {
    /// True while a call is still live (ringing/dialing/connected). Demo and
    /// non-routing drivers default to false; route telemetry must never be
    /// applied to an ended call.
    var hasLiveCall: Bool { false }
    /// Demo/non-system drivers have no CallKit/LCK surface to report to.
    func systemReportState(gatewayId: String) -> SystemReportState { .unknown }
    func canAttemptSystemReport(gatewayId: String) -> Bool { false }
    func isRinging(gatewayId: String) -> Bool { false }
    var activeCallRecord: CallRecord? { nil }
    var heldCallRecords: [CallRecord] { [] }
    var conferenceRecord: ConferenceRecord? { nil }
    var onRouteState: ((CallRouteState) -> Void)? {
        get { nil }
        set { /* demo: routing unavailable */ }
    }
    var onRouteNotice: ((String, Bool) -> Void)? {
        get { nil }
        set { /* demo: routing unavailable */ }
    }
    var onAudioStatus: ((String?) -> Void)? {
        get { nil }
        set { /* demo: no audio lifecycle */ }
    }
    /// Changes the Auto/Direct/Relay mode for the active call.
    func selectRouteMode(_ mode: MediaRouteMode) {}
    /// The currently selected route mode for the bound gateway.
    var routeModeDefault: MediaRouteMode { .auto }
    func setDefaultLineId(_ lineId: String?) {}
    func holdActive() {}
    func resume(callId: String) {}
    func mergeHeldCalls() {}
    func endConferenceLeg(callId: String) {}
    func holdConferenceLeg(callId: String, held: Bool) {}
    func playConferenceDTMF(_ digit: String, callId: String?) {}
    func splitConference(callId: String) {}
}
