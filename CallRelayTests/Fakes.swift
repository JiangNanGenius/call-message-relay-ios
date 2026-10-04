import Foundation
import CallKit
@testable import CallRelay

// MARK: - In-memory keychain

final class DictionaryKeychain: KeychainWrapping {
    var storage: [String: Data] = [:]
    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func readData(service: String, account: String) -> Data? { storage[key(service, account)] }

    func saveData(_ data: Data, service: String, account: String, accessibility: KeychainAccessibility) throws {
        storage[key(service, account)] = data
    }

    func delete(service: String, account: String) { storage.removeValue(forKey: key(service, account)) }
}

// MARK: - Fake media

final class FakeMediaSession: CallMediaSession {
    var onState: ((MediaState) -> Void)?
    var onQuality: ((MediaQuality) -> Void)?
    var makeOfferError: Error?
    var closeCount = 0
    var activationCount = 0
    var muted = false
    var speaker = false
    var afterApplyAnswer: (() -> Void)?
    var makeOfferCount = 0
    /// Direct in-app answer path activations (no CallKit didActivate).
    var activateWithoutCallKitCount = 0
    var deactivateWithoutCallKitCount = 0
    /// When false, a direct-answer session activation fails.
    var activateWithoutCallKitResult = true

    func makeOffer(ice: ICEConfiguration, relayOnly: Bool) async throws -> String {
        makeOfferCount += 1
        if let makeOfferError { throw makeOfferError }
        return "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\na=rtpmap:0 PCMU/8000\r\n"
    }

    func applyAnswer(_ sdp: String) async throws {
        afterApplyAnswer?()
    }

    func setMicMuted(_ muted: Bool) { self.muted = muted }
    func setSpeakerphone(_ enabled: Bool) throws { speaker = enabled }
    func audioActivated(with session: AVAudioSession) { activationCount += 1 }
    func audioDeactivated(with session: AVAudioSession) {}
    func activateAudioWithoutCallKit() -> Bool {
        activateWithoutCallKitCount += 1
        return activateWithoutCallKitResult
    }
    func deactivateAudioWithoutCallKit() { deactivateWithoutCallKitCount += 1 }
    func close() { closeCount += 1 }
}

import AVFoundation

@MainActor
final class FakeMediaProvider: MediaSessionProviding {
    let session: FakeMediaSession
    var createCount = 0
    /// When true, each request yields a fresh fake so per-call teardown can be
    /// observed (the default shared instance mirrors the old single-call tests).
    var createsNewSessions = false
    private(set) var created: [FakeMediaSession] = []

    init(session: FakeMediaSession) { self.session = session }

    func makeSession() -> CallMediaSession {
        createCount += 1
        if createsNewSessions {
            let clone = FakeMediaSession()
            created.append(clone)
            return clone
        }
        return session
    }
}

// MARK: - Fake CallKit

@MainActor
final class FakeCallKit: CallKitControlling {
    weak var director: CallDirecting?
    var incoming: [(uuid: UUID, handle: String)] = []
    var updates: [(uuid: UUID, handle: String)] = []
    var connecting: [UUID] = []
    var connected: [UUID] = []
    var ended: [(uuid: UUID, reason: CXCallEndedReason)] = []
    var startRequests: [UUID] = []
    var heldReports: [(uuid: UUID, held: Bool)] = []
    /// When false, `reportIncoming` mimics a CallKit rejection.
    var reportIncomingResult = true
    /// Fail the first `reportIncoming` after arming; continuations resume
    /// FIFO with `resumeReport`. Lets tests interleave ends/resets/overlapping
    /// pushes with the awaits.
    var armReportWait = false
    private var reportWaiters: [CheckedContinuation<Bool, Never>] = []
    func resumeReport(_ accepted: Bool) {
        guard !reportWaiters.isEmpty else { return }
        reportWaiters.removeFirst().resume(returning: accepted)
    }
    /// Raw `CXErrorCodeIncomingCallError` reported with a rejection.
    var reportIncomingErrorCode: Int?
    private(set) var lastIncomingReportErrorCode: Int?
    /// When set, `requestAnswer` fails like an unknown/ended system call.
    var requestAnswerError: Error?
    var requestAnswerCalls: [UUID] = []
    /// Simulates the provider delegate reacting to a successful answer.
    var onRequestAnswer: ((UUID) -> Void)?
    var requestEndError: Error?
    var requestEndCalls: [UUID] = []

    func reportIncoming(uuid: UUID, handle: String, isVideo: Bool) async -> Bool {
        incoming.append((uuid, handle))
        if armReportWait {
            armReportWait = false
            let accepted = await withCheckedContinuation { reportWaiters.append($0) }
            lastIncomingReportErrorCode = accepted ? nil : (reportIncomingErrorCode ?? 0)
            return accepted
        }
        lastIncomingReportErrorCode = reportIncomingResult ? nil : (reportIncomingErrorCode ?? 0)
        return reportIncomingResult
    }
    func updateIncoming(uuid: UUID, handle: String) { updates.append((uuid, handle)) }
    func requestStartOutgoing(uuid: UUID, handle: String) async throws { startRequests.append(uuid) }
    func reportOutgoingConnecting(uuid: UUID) { connecting.append(uuid) }
    func reportConnected(uuid: UUID, startedAt: Date?) { connected.append(uuid) }
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) async { ended.append((uuid, reason)) }
    func reportHeld(uuid: UUID, held: Bool) { heldReports.append((uuid, held)) }
    func requestEnd(uuid: UUID) async throws {
        requestEndCalls.append(uuid)
        if let requestEndError { throw requestEndError }
    }
    func requestAnswer(uuid: UUID) async throws {
        requestAnswerCalls.append(uuid)
        if let requestAnswerError { throw requestAnswerError }
        onRequestAnswer?(uuid)
    }
    func requestMute(uuid: UUID, muted: Bool) async throws {}
    func requestDTMF(uuid: UUID, digit: String) async throws {}
    func invalidate() {}
}

// MARK: - Fake gateway with controllable timing

@MainActor
final class FakeGatewayAPI: GatewayAPI {
    struct IdemCall { let id: String; let key: String; let to: String }

    var identityResponse: IdentityResponse?
    var dialResult: Result<CallRecord, Error> = .failure(APIError.notReady(""))
    var offerError: Error?
    var iceError: Error?
    var activeRecordForPoll: CallRecord?

    var dials: [IdemCall] = []
    var answers: [String] = []
    var rejects: [String] = []
    var hangups: [String] = []
    var dtmfs: [(id: String, digit: String)] = []
    var offers: [String] = []

    // Unified multi-call / conference surface
    var holdError: Error?
    var resumeError: Error?
    var holds: [String] = []
    var resumes: [String] = []
    var dialLines: [String?] = []
    var setNumberCalls: [(lineId: String, number: String)] = []
    var setNumberResult: Result<AuthorizedLine, Error> = .failure(APIError.notReady("set number not configured"))
    var authorizedLinesStub: [AuthorizedLine] = []
    var authorizedLinesError: Error?
    private(set) var authorizedLinesCallCount = 0
    /// When armed, the next authorizedLines() call blocks until
    /// resumeAuthorizedLines; used to deliver a stale response after rebind.
    private var linesWaiter: CheckedContinuation<[AuthorizedLine], Error>?
    private var linesArmed = false
    private var numberWaiter: CheckedContinuation<AuthorizedLine, Error>?
    private var numberArmed = false
    var mergeError: Error?

    // MARK: Direct route (probe/commit/rollback)
    var attachProbeResult: Result<WebRTCAnswer, Error> = .success(
        WebRTCAnswer(sdp: "v=0\r\n", type: "answer", iceMode: "all"))
    private(set) var attachProbeCalls: [String] = []
    /// When armed once, the next attach parks until resumeAttach/cancel
    /// (hung-attach routing tests). Cancellation mirrors a real
    /// URLSession.data(for:) throwing on task cancel.
    private var attachArmed = false
    private var attachContinuation: CheckedContinuation<WebRTCAnswer, Error>?
    private(set) var attachCancelled = false

    func armAttachWait() { attachArmed = true }
    func resumeAttach(with result: Result<WebRTCAnswer, Error>) {
        attachContinuation?.resume(with: result)
        attachContinuation = nil
    }

    var commitError: Error?
    private(set) var commitCalls: [String] = []
    private(set) var preflightCommitIds: [String?] = []
    private(set) var discardPreflightIds: [String] = []
    private(set) var deletedThreadKeys: [String] = []
    private var commitContinuation: CheckedContinuation<Void, Error>?
    private var commitArmed = false
    var discardProbeCalls: [String] = []
    var measureRequestCallCount = 0

    func armCommitWait() { commitArmed = true }
    var onCommit: (() -> Void)?
    func resumeCommit(with result: Result<Void, Error>) {
        commitContinuation?.resume(with: result)
        commitContinuation = nil
    }

    func armAuthorizedLinesWait() { linesArmed = true }
    func resumeAuthorizedLines(with result: Result<[AuthorizedLine], Error>) {
        if let waiter = linesWaiter {
            linesWaiter = nil
            waiter.resume(with: result)
        }
    }
    func armSetNumberWait() { numberArmed = true }
    func resumeSetNumber(with result: Result<AuthorizedLine, Error>) {
        if let waiter = numberWaiter {
            numberWaiter = nil
            waiter.resume(with: result)
        }
    }
    var mergeResult: ConferenceRecord?
    var merges: [[String]] = []
    var conferenceOffers: [(conferenceId: String, sdp: String)] = []
    var closeConferences: [String] = []
    var removedLegs: [(conferenceId: String, callId: String)] = []
    var legHolds: [(conferenceId: String, callId: String, held: Bool)] = []
    var legDTMFs: [(conferenceId: String, callId: String, digit: String)] = []
    var splits: [(conferenceId: String, callId: String)] = []
    var conferenceSnapshot: ConferenceRecord?
    /// Ordered trace of call-affecting commands, used to assert ordering.
    var actionLog: [String] = []

    // SMS surface
    var threads: [MessageThread] = []
    var threadPages: [String: [MessageRecord]] = [:]
    /// Per-key errors so tests can make one line candidate fail while
    /// another succeeds (unqualified-key resolution order).
    var threadPageErrors: [String: Error] = [:]
    /// Every threadKey requested via listThreadMessages, in order.
    private(set) var requestedThreadKeys: [String] = []
    var threadHasMore = false
    var sentMessages: [SentSMS] = []
    /// Parallel to `sentMessages`: the line each send requested.
    var sentLineIDs: [String?] = []
    var sendResult: Result<MessageRecord, Error> = .failure(APIError.notReady("send not configured"))
    var idempotentReplays: [String: MessageRecord] = [:]
    var readMarked: [String] = []
    var onSendEntered: ((String) -> Void)?
    private var sendContinuation: CheckedContinuation<MessageRecord, Error>?
    var autoResumeSend = true

    // Voicemail surface
    var voicemailsStub: [VoicemailRecord] = []
    var voicemailDeleteResult: Result<Void, Error> = .success(())
    private(set) var voicemailDeletes: [String] = []

    struct SentSMS { let to: String; let body: String; let key: String }

    var onDialEntered: (() -> Void)?
    private var dialContinuation: CheckedContinuation<CallRecord, Error>?
    var autoResumeDial = true

    func identity() async throws -> IdentityResponse {
        if let identityResponse { return identityResponse }
        throw APIError.network(URLError(.cannotFindHost))
    }
    func gatewayInfo() async throws -> GatewayResponse {
        GatewayResponse(id: "gw", name: "GW", lineID: nil, transport: "tailnet", capabilities: nil)
    }
    var lineError: Error?
    private(set) var lineCallCount = 0
    private var lineWaiter: CheckedContinuation<LineStatus, Error>?
    private var lineArmed = false
    func armLineWait() { lineArmed = true }
    func resumeLine(with result: Result<LineStatus, Error>) {
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(with: result)
        }
    }
    func line() async throws -> LineStatus {
        lineCallCount += 1
        if lineArmed {
            lineArmed = false
            return try await withCheckedThrowingContinuation { cont in
                lineWaiter = cont
            }
        }
        if let lineError { throw lineError }
        return LineStatus.demoReady()
    }
    func listCalls(limit: Int) async throws -> [CallRecord] { [] }
    func listVoicemails() async throws -> [VoicemailRecord] { voicemailsStub }
    func deleteVoicemail(id: String) async throws {
        voicemailDeletes.append(id)
        try voicemailDeleteResult.get()
    }
    /// Reconciliation stub: tests arm the gateway's active set explicitly.
    var activeCallsStub: [CallRecord] = []
    var activeCallsError: Error?
    private(set) var activeCallsCallCount = 0
    func activeCalls() async throws -> [CallRecord] {
        activeCallsCallCount += 1
        if let activeCallsError { throw activeCallsError }
        return activeCallsStub
    }
    /// When armed, the next fetchCall parks until resumeFetchCall, so tests
    /// can interleave a terminal event during the verification await.
    private var fetchWaiter: CheckedContinuation<CallRecord, Error>?
    private var fetchArmed = false
    func armFetchCallWait() { fetchArmed = true }
    var fetchCallParked: Bool { fetchWaiter != nil }
    func resumeFetchCall(with result: Result<CallRecord, Error>) {
        fetchWaiter?.resume(with: result)
        fetchWaiter = nil
    }
    func fetchCall(id: String) async throws -> CallRecord {
        if fetchArmed {
            fetchArmed = false
            return try await withCheckedThrowingContinuation { cont in
                fetchWaiter = cont
            }
        }
        if let match = activeCallsStub.first(where: { $0.id == id }) { return match }
        if let activeRecordForPoll { return activeRecordForPoll }
        throw APIError.http(status: 404, code: "CB-CALL-006", message: "not found")
    }

    func dial(to: String, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        dials.append(IdemCall(id: clientCallId, key: idempotencyKey, to: to))
        actionLog.append("dial:\(to)")
        onDialEntered?()
        if autoResumeDial {
            return try dialResult.get()
        }
        return try await withCheckedThrowingContinuation { cont in
            dialContinuation = cont
        }
    }

    func dial(to: String, lineId: String?, clientCallId: String, idempotencyKey: String) async throws -> CallRecord {
        dialLines.append(lineId)
        if let lineId { actionLog.append("dialLine:\(lineId)") }
        return try await dial(to: to, clientCallId: clientCallId, idempotencyKey: idempotencyKey)
    }

    func resumeDial(_ result: Result<CallRecord, Error>) {
        dialContinuation?.resume(with: result)
        dialContinuation = nil
    }

    // MARK: Unified lines

    func authorizedLines() async throws -> [AuthorizedLine] {
        authorizedLinesCallCount += 1
        if let authorizedLinesError { throw authorizedLinesError }
        if linesArmed {
            linesArmed = false
            return try await withCheckedThrowingContinuation { cont in
                linesWaiter = cont
            }
        }
        return authorizedLinesStub
    }

    func setLineNumber(_ lineId: String, phoneNumber: String) async throws -> AuthorizedLine {
        setNumberCalls.append((lineId, phoneNumber))
        if numberArmed {
            numberArmed = false
            return try await withCheckedThrowingContinuation { cont in
                numberWaiter = cont
            }
        }
        return try setNumberResult.get()
    }

    var setDefaultLineCalls: [String] = []
    var setDefaultLineError: Error?
    /// Per-line artificial latency so tests can force an older, slower
    /// preference PUT to overlap a newer choice.
    var setDefaultLineDelays: [String: TimeInterval] = [:]
    func setDefaultLine(_ lineId: String, idempotencyKey: String) async throws {
        if let delay = setDefaultLineDelays[lineId], delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let setDefaultLineError { throw setDefaultLineError }
        setDefaultLineCalls.append(lineId)
    }

    func answer(callId: String, idempotencyKey: String) async throws {
        answers.append(callId)
        actionLog.append("answer:\(callId)")
    }
    func reject(callId: String, idempotencyKey: String) async throws { rejects.append(callId) }
    func hangup(callId: String, idempotencyKey: String) async throws {
        hangups.append(callId)
        actionLog.append("hangup:\(callId)")
    }
    func hold(callId: String, idempotencyKey: String) async throws {
        holds.append(callId)
        actionLog.append("hold:\(callId)")
        if let holdError { throw holdError }
    }
    func resume(callId: String, idempotencyKey: String) async throws {
        resumes.append(callId)
        actionLog.append("resume:\(callId)")
        if let resumeError { throw resumeError }
    }
    func dtmf(callId: String, digit: String, idempotencyKey: String) async throws {
        dtmfs.append((callId, digit))
    }

    func webRTCOffer(callId: String, sdp: String, transport: String, idempotencyKey: String) async throws -> WebRTCAnswer {
        offers.append(callId)
        if let offerError { throw offerError }
        return WebRTCAnswer(sdp: "v=0\r\n", type: "answer", iceMode: "relay")
    }

    /// When set, returned instead of the default ICE-only configuration
    /// (e.g. to advertise the WSS media transport).
    var iceConfigOverride: ICEConfiguration?
    /// When set, returned by mediaWebSocketRequest (default throws notReady).
    var mediaWSRequestOverride: URLRequest?

    func iceConfiguration(callId: String) async throws -> ICEConfiguration {
        if let iceError { throw iceError }
        if let iceConfigOverride { return iceConfigOverride }
        return ICEConfiguration(
            policy: "tailnet-turn",
            iceServers: [ICEServer(urls: ["turn:turn.example:3478?transport=udp"], username: "u", credential: "c")],
            expiresAt: "2026-10-01T00:00:00Z"
        )
    }

    func mediaWebSocketRequest(callId: String) async throws -> URLRequest {
        if let mediaWSRequestOverride { return mediaWSRequestOverride }
        throw APIError.notReady("当前配对不支持 WebSocket 音频。")
    }

    func sync(after: Int64, limit: Int) async throws -> SyncResponse {
        SyncResponse(from: after, to: after, hasMore: false, changes: [])
    }
    func registerPush(registration: PushRegistration, idempotencyKey: String) async throws {}

    // MARK: Conference (unified v2)

    func merge(calls: [String], idempotencyKey: String) async throws -> ConferenceRecord {
        merges.append(calls)
        actionLog.append("merge:\(calls.joined(separator: ","))")
        if let mergeError { throw mergeError }
        if let mergeResult { return mergeResult }
        throw APIError.notReady("会议未配置")
    }

    func conference(id: String) async throws -> ConferenceRecord {
        if let conferenceSnapshot { return conferenceSnapshot }
        throw APIError.notReady("会议未配置")
    }

    func conferenceOffer(
        conferenceId: String, sdp: String, idempotencyKey: String
    ) async throws -> WebRTCAnswer {
        conferenceOffers.append((conferenceId, sdp))
        actionLog.append("conferenceOffer:\(conferenceId)")
        if let offerError { throw offerError }
        return WebRTCAnswer(sdp: "v=0\r\n", type: "answer", iceMode: "relay")
    }

    func closeConference(id: String, idempotencyKey: String) async throws {
        closeConferences.append(id)
        actionLog.append("closeConference:\(id)")
    }

    func removeConferenceLeg(conferenceId: String, callId: String, idempotencyKey: String) async throws {
        removedLegs.append((conferenceId, callId))
        actionLog.append("removeLeg:\(callId)")
    }

    func setConferenceLegHeld(conferenceId: String, callId: String, held: Bool, idempotencyKey: String) async throws {
        legHolds.append((conferenceId, callId, held))
        actionLog.append(held ? "legHold:\(callId)" : "legResume:\(callId)")
    }

    func conferenceLegDTMF(conferenceId: String, callId: String, digit: String, idempotencyKey: String) async throws {
        legDTMFs.append((conferenceId, callId, digit))
    }

    func splitConference(id: String, callId: String, idempotencyKey: String) async throws {
        splits.append((id, callId))
        actionLog.append("split:\(callId)")
    }

    // MARK: SMS

    func listThreads() async throws -> [MessageThread] { threads }

    func listMessages(after: Int64, limit: Int) async throws -> [MessageRecord] { extraMessages }
    var extraMessages: [MessageRecord] = []

    func listThreadMessages(
        threadKey: String, beforeCreatedAt: Int64?, beforeID: String?, limit: Int
    ) async throws -> ThreadMessagePage {
        requestedThreadKeys.append(threadKey)
        if let error = threadPageErrors[threadKey] { throw error }
        return ThreadMessagePage(messages: threadPages[threadKey] ?? [], hasMore: threadHasMore)
    }

    func sendMessage(to: String, body: String, idempotencyKey: String) async throws -> MessageRecord {
        try await sendMessage(to: to, body: body, lineId: nil, idempotencyKey: idempotencyKey)
    }

    /// Captures the requested line so tests can prove per-line send/retry
    /// behavior (a retry must reuse the entry's captured line).
    func sendMessage(to: String, body: String, lineId: String?, idempotencyKey: String) async throws -> MessageRecord {
        if let replay = idempotentReplays[idempotencyKey] { return replay }
        sentMessages.append(SentSMS(to: to, body: body, key: idempotencyKey))
        sentLineIDs.append(lineId)
        onSendEntered?(idempotencyKey)
        if autoResumeSend {
            return try sendResult.get()
        }
        return try await withCheckedThrowingContinuation { cont in
            sendContinuation = cont
        }
    }

    func resumeSend(_ result: Result<MessageRecord, Error>) {
        sendContinuation?.resume(with: result)
        sendContinuation = nil
    }

    func markMessageRead(id: String, idempotencyKey: String) async throws {
        readMarked.append(id)
    }

    func attachMediaProbe(callId: String, sdp: String) async throws -> WebRTCAnswer {
        attachProbeCalls.append(callId)
        if attachArmed {
            attachArmed = false
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebRTCAnswer, Error>) in
                    self.attachContinuation = cont
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.attachCancelled = true
                    self.attachContinuation?.resume(throwing: CancellationError())
                    self.attachContinuation = nil
                }
            }
        }
        return try attachProbeResult.get()
    }
    func commitMediaProbe(callId: String, preflightId: String?) async throws {
        commitCalls.append(callId)
        preflightCommitIds.append(preflightId)
        onCommit?()
        if commitArmed {
            commitArmed = false
            try await withCheckedThrowingContinuation { commitContinuation = $0 }
            return
        }
        if let commitError { throw commitError }
    }
    func discardMediaProbe(callId: String) async throws {
        discardProbeCalls.append(callId)
    }
    func iceConfiguration() async throws -> ICEConfiguration {
        throw APIError.notReady("demo")
    }
    func attachMediaPreflight(sdp: String) async throws -> V2PreflightAnswer {
        throw APIError.notReady("demo")
    }
    func discardMediaPreflight(preflightId: String) async throws {
        discardPreflightIds.append(preflightId)
    }
    func deleteThread(threadKey: String) async throws {
        deletedThreadKeys.append(threadKey)
    }
    func mediaMeasureWebSocketRequest(callId: String) async throws -> URLRequest {
        measureRequestCallCount += 1
        return URLRequest(url: URL(string: "wss://example.test/calls/\(callId)/media/measure")!)
    }
}

// MARK: - Async pumping

@MainActor
func pumpMainActor(_ times: Int = 5) async {
    for _ in 0..<times {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        await Task.yield()
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

func makeCallRecord(
    id: String,
    state: CallState,
    direction: CallDirection = .outbound,
    peer: String = "555-0123",
    startedAt: Int64? = nil
) -> CallRecord {
    let now = Date().unixMilliseconds
    return CallRecord(
        id: id, gatewayID: "gw", lineID: "gw:line", direction: direction, peer: peer,
        state: state, startedAt: startedAt ?? now - 1000,
        connectedAt: state == .active ? now : nil, endedAt: nil, endReason: nil,
        recordingId: nil, recordingState: nil, recordingDurationMs: nil
    )
}

func makeConferenceRecord(id: String = "conf-1", legs: [CallRecord]) -> ConferenceRecord {
    ConferenceRecord(
        id: id, hostDeviceId: "device-1", state: "active",
        createdAt: Date().unixMilliseconds, graceDeadline: nil, legs: legs
    )
}
