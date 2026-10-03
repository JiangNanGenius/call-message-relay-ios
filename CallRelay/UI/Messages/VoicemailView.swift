import SwiftUI
import AVFoundation
import Combine

/// Playback policy for voicemail: never touches the shared audio session while
/// a gateway call is active (CallKit owns it), cancels stale async fetches by
/// generation, stops the previous clip when a new one starts, and reports
/// natural end-of-clip so the UI can clear itself without a manual stop.
protocol VoicemailAudioPlaying: AnyObject {
    var duration: TimeInterval { get }
    /// Called once when playback ends on its own (`stop()` does not fire it).
    var onCompletion: (() -> Void)? { get set }
    func play() -> Bool
    func stop()
}

protocol VoicemailAudioSessionControlling: AnyObject {
    func activate() throws
    func deactivate()
}

/// AVAudioPlayer wrapper; the delegate forwarding is the only way to learn
/// that a clip reached its natural end while the screen stayed open.
final class SystemVoicemailPlayer: NSObject, VoicemailAudioPlaying {
    private let player: AVAudioPlayer
    var onCompletion: (() -> Void)?

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }
    func play() -> Bool { player.play() }
    func stop() {
        player.delegate = nil
        player.stop()
    }

    /// AVAudioPlayer delivers delegate callbacks on the main thread; keep an
    /// explicit hop so a callback from another run-loop mode can never touch
    /// the main-actor playback state off-main.
    private func notifyCompletion() {
        if Thread.isMainThread {
            onCompletion?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onCompletion?() }
        }
    }
}

extension SystemVoicemailPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        notifyCompletion()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        notifyCompletion()
    }
}

final class SystemVoicemailAudioSession: VoicemailAudioSessionControlling {
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
final class VoicemailPlaybackController: ObservableObject {
    @Published private(set) var playingId: String?
    @Published var errorMessage: String?

    /// Live probe for "a call currently owns the shared audio session",
    /// supplied by the view (active gateway call OR a CallKit-activated
    /// session). `sessionActive` alone is stale ownership, never proof that
    /// deactivation is safe.
    var isCallActive: () -> Bool = { false }

    private let session: VoicemailAudioSessionControlling
    private let makePlayer: (Data) throws -> VoicemailAudioPlaying
    private var player: VoicemailAudioPlaying?
    private var sessionActive = false
    private var generation = 0

    init(
        session: VoicemailAudioSessionControlling = SystemVoicemailAudioSession(),
        makePlayer: @escaping (Data) throws -> VoicemailAudioPlaying = { try SystemVoicemailPlayer(data: $0) }
    ) {
        self.session = session
        self.makePlayer = makePlayer
    }

    /// Marks the start of an async audio fetch. The returned token is only
    /// valid until the next request/stop; a fetch that finishes later must
    /// not start playback.
    func beginRequest(_ id: String) -> Int {
        stopInternal(deactivateSession: true)
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool { token == generation }

    func play(id: String, data: Data) {
        stopCurrentPlayback()
        guard !isCallActive() else {
            errorMessage = "通话期间不播放语音留言。"
            stopInternal(deactivateSession: true)
            return
        }
        do {
            try session.activate()
            sessionActive = true
        } catch {
            errorMessage = "无法启用音频播放。"
            stopInternal(deactivateSession: true)
            return
        }
        let audioPlayer: VoicemailAudioPlaying
        do {
            audioPlayer = try makePlayer(data)
        } catch {
            errorMessage = "留言音频无法播放。"
            stopInternal(deactivateSession: true)
            return
        }
        player = audioPlayer
        playingId = id
        errorMessage = nil
        // Scope natural completion to this clip; any stop/newer play bumps the
        // generation first, so a late callback from a replaced player is inert.
        let playbackGeneration = generation
        audioPlayer.onCompletion = { [weak self] in
            self?.playbackDidFinish(generation: playbackGeneration)
        }
        if !audioPlayer.play() {
            errorMessage = "播放失败，请重试。"
            stopInternal(deactivateSession: true)
        }
    }

    func toggle(id: String, data: Data) {
        if playingId == id {
            stop()
        } else {
            play(id: id, data: data)
        }
    }

    func stop() {
        stopInternal(deactivateSession: true)
    }

    /// Called when the call state changes; never continues playback during a
    /// live call. CallKit now owns the shared session, so stop the clip and
    /// drop the local ownership claim without deactivating anything.
    func handleCallStateChange() {
        guard isCallActive() else { return }
        if playingId != nil {
            errorMessage = "通话已开始，语音留言播放已停止。"
        }
        stopInternal(deactivateSession: false)
    }

    /// Stops the current clip but keeps any voicemail-owned session for the
    /// next clip; used when starting an overlapping request.
    private func stopCurrentPlayback() {
        generation += 1
        releasePlayer()
        playingId = nil
    }

    /// Natural (or decode-error) end of the clip that currently matches the
    /// generation it was started with.
    private func playbackDidFinish(generation finished: Int) {
        guard finished == generation, player != nil else { return }
        stopInternal(deactivateSession: true)
    }

    private func stopInternal(deactivateSession: Bool) {
        generation += 1
        releasePlayer()
        playingId = nil
        guard sessionActive else { return }
        // `sessionActive` only records that voicemail once activated the
        // session, not that it still owns it. When a live call is present,
        // hand the session over silently: deactivating here would kill the
        // call's audio.
        if deactivateSession, !isCallActive() {
            session.deactivate()
        }
        sessionActive = false
    }

    private func releasePlayer() {
        player?.onCompletion = nil
        player?.stop()
        player = nil
    }
}

/// 语音留言：按线路显示，点按后在停留本页期间播放 WAV 语音。
struct VoicemailView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var playback = VoicemailPlaybackController()
    @State private var pendingDelete: VoicemailRecord?

    var body: some View {
        List {
            if model.voicemails.isEmpty {
                ContentUnavailableView("还没有语音留言", systemImage: "recordingtape",
                                       description: Text("无人接听或设备离线时，来电会自动转入语音留言。"))
            }
            ForEach(model.voicemails) { voicemail in
                HStack(spacing: 12) {
                    Button {
                        Task { await play(voicemail) }
                    } label: {
                        Image(systemName: playback.playingId == voicemail.id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.playingId == voicemail.id ? "停止播放" : "播放留言")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voicemail.peer.isEmpty ? "未知号码" : voicemail.peer)
                            .font(.body.weight(.medium))
                        HStack(spacing: 8) {
                            if let lineName = voicemail.lineName, !lineName.isEmpty {
                                Text(lineName)
                            }
                            Text(Self.duration(voicemail.durationMs))
                            Text(Self.timestamp(voicemail.createdAt))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = voicemail
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .accessibilityIdentifier("delete-voicemail")
                }
            }
            if let message = playback.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if let message = model.voicemailDeleteError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle("语音留言")
        .task {
            updateCallGuard()
            await model.refreshVoicemails()
        }
        .onChange(of: model.activeCall != nil) { _, _ in
            playback.handleCallStateChange()
        }
        .onChange(of: model.lastDeletedVoicemailId) { _, deletedId in
            // Local delete or another device's `voicemail.deleted`: never
            // keep playing a clip that no longer exists.
            if let deletedId, playback.playingId == deletedId {
                playback.stop()
            }
        }
        .refreshable { await model.refreshVoicemails() }
        .onDisappear { playback.stop() }
        .confirmationDialog(
            "删除这条语音留言？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除留言", role: .destructive) {
                guard let voicemail = pendingDelete else { return }
                pendingDelete = nil
                Task { await model.deleteVoicemail(voicemail.id) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将从网关删除录音文件，此操作不可撤销。")
        }
    }

    /// CallKit can own the shared `AVAudioSession` before `model.activeCall`
    /// catches up, so the guard must also consult the session CallKit handed
    /// over. Either signal means "never deactivate".
    private func updateCallGuard() {
        playback.isCallActive = {
            model.activeCall != nil || AudioSessionBridge.shared.activeSession != nil
        }
    }

    private func play(_ voicemail: VoicemailRecord) async {
        updateCallGuard()
        if playback.playingId == voicemail.id {
            playback.stop()
            return
        }
        let token = playback.beginRequest(voicemail.id)
        guard let data = await model.voicemailData(voicemail.id), playback.isCurrent(token) else {
            if playback.isCurrent(token) {
                playback.errorMessage = "留言音频暂时无法获取。"
            }
            return
        }
        playback.play(id: voicemail.id, data: data)
    }

    private static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
