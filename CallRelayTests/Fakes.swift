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

    func makeOffer(ice: ICEConfiguration, relayOnly: Bool) async throws -> String {
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
    var connecting: [UUID] = []
    var connected: [UUID] = []
    var ended: [(uuid: UUID, reason: CXCallEndedReason)] = []
    var startRequests: [UUID] = []
    var heldReports: [(uuid: UUID, held: Bool)] = []

    func reportIncoming(uuid: UUID, handle: String, isVideo: Bool) async -> Bool {
        incoming.append((uuid, handle))
        return true
    }
    func requestStartOutgoing(uuid: UUID, handle: String) async throws { startRequests.append(uuid) }
    func reportOutgoingConnecting(uuid: UUID) { connecting.append(uuid) }
    func reportConnected(uuid: UUID, startedAt: Date?) { connected.append(uuid) }
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) async { ended.append((uuid, reason)) }
    func reportHeld(uuid: UUID, held: Bool) { heldReports.append((uuid, held)) }
    func requestEnd(uuid: UUID) async throws {}
    func requestAnswer(uuid: UUID) async throws {}
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
    var mergeError: Error?
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
    var threadHasMore = false
    var sentMessages: [SentSMS] = []
    var sendResult: Result<MessageRecord, Error> = .failure(APIError.notReady("send not configured"))
    var idempotentReplays: [String: MessageRecord] = [:]
    var readMarked: [String] = []
    var onSendEntered: ((String) -> Void)?
    private var sendContinuation: CheckedContinuation<MessageRecord, Error>?
    var autoResumeSend = true

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
    func line() async throws -> LineStatus { LineStatus.demoReady() }
    func listCalls(limit: Int) async throws -> [CallRecord] { [] }
    func fetchCall(id: String) async throws -> CallRecord {
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

    func iceConfiguration(callId: String) async throws -> ICEConfiguration {
        if let iceError { throw iceError }
        return ICEConfiguration(
            policy: "tailnet-turn",
            iceServers: [ICEServer(urls: ["turn:turn.example:3478?transport=udp"], username: "u", credential: "c")],
            expiresAt: "2026-10-01T00:00:00Z"
        )
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
        ThreadMessagePage(messages: threadPages[threadKey] ?? [], hasMore: threadHasMore)
    }

    func sendMessage(to: String, body: String, idempotencyKey: String) async throws -> MessageRecord {
        if let replay = idempotentReplays[idempotencyKey] { return replay }
        sentMessages.append(SentSMS(to: to, body: body, key: idempotencyKey))
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
