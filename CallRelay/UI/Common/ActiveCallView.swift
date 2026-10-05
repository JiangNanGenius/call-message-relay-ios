import SwiftUI

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var group = CallGroupStore.shared
    @State private var muted = false
    @State private var speaker = false
    @State private var showKeypad = false
    @State private var selectedLegID: String?

    private var call: ActiveCallViewState? { model.activeCall }
    private var heldCalls: [CallRecord] { group.heldCalls }
    private var conference: ConferenceRecord? { group.conference }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer(minLength: 4)
                header

                // Degraded/recovering audio is worth showing; a plain
                // "audio connected" is redundant with the active status.
                if let quality = model.quality, !quality.summary.isEmpty,
                   !quality.isPlainConnected {
                    Text(quality.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Honest temporary state while audio ownership is unavailable
                // (another app holds the session, interruption pending, or
                // the audio server is resetting). Cleared on real activation.
                if let audioStatus = model.audioStatus {
                    Text(audioStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("call.audioStatus")
                }

                if conference == nil, !heldCalls.isEmpty {
                    heldSection
                }
                if conference != nil {
                    conferenceSection
                }

                Spacer(minLength: 4)

                if call?.phase == .held, let callId = call?.gatewayCallId {
                    Button {
                        group.resume(callId: callId)
                    } label: {
                        Text(String(localized: "恢复通话"))
                            .font(.headline)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 8)
                } else {
                    controls
                }

                footerButtons
            }
            .padding()
            // Centered call column on iPad/landscape; unchanged on iPhone.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showKeypad) { keypadSheet }
        }
        .onChange(of: conference?.id) { _, _ in
            if !(conference?.legs.contains { $0.id == selectedLegID } ?? false) {
                selectedLegID = conference?.legs.first?.id
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: model.isDemo ? "wand.and.stars" : (conference == nil ? "person.crop.circle.fill" : "person.3.fill"))
                .resizable().scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(call?.peer ?? String(localized: "未知"))
                .font(.system(size: 30, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(statusText)
                .font(.headline)
                .foregroundStyle(statusColor)

            if !model.isDemo || LaunchArguments.isRoutePreview {
                if call?.phase.isLive == true {
                    InCallRouteMenu()
                }
            }

            if conference != nil {
                Text(String(localized: "多方会议 · \(conference?.legs.count ?? 0) 方"))
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            if model.isDemo {
                Text(String(localized: "演示模式"))
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: Held calls

    private var heldSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "保持中的通话"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(heldCalls) { record in
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.peer ?? String(localized: "未知号码"))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(String(localized: "\(CallGroupStore.lineLabel(record.lineID)) · 已保持"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(String(localized: "恢复")) { group.resume(callId: record.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Conference

    private var conferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "会议成员"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(localized: "轻点左侧圆点选择通话方"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(group.conferenceLegs) { leg in
                HStack(spacing: 10) {
                    Button {
                        selectedLegID = leg.id
                    } label: {
                        Image(systemName: selectedLegID == leg.id ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedLegID == leg.id ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selectedLegID == leg.id ? String(localized: "已选中的通话方") : String(localized: "选择该通话方"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(leg.peer)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(leg.lineLabel) · \(leg.held ? String(localized: "已保持") : String(localized: "参与中"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 6)

                    Button(leg.held ? String(localized: "恢复") : String(localized: "保持")) {
                        group.setConferenceLegHeld(callId: leg.id, held: !leg.held)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button(String(localized: "移除"), role: .destructive) {
                        group.endConferenceLeg(callId: leg.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(10)
                .background(
                    selectedLegID == leg.id ? Color.accentColor.opacity(0.10) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }

            if let selectedLegID {
                Button(String(localized: "将选中一方移出会议")) {
                    group.splitConference(callId: selectedLegID)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 26) {
            CallControlButton(active: muted, icon: "mic.slash.fill", label: String(localized: "静音")) {
                muted.toggle()
                model.setMuted(muted)
            }
            CallControlButton(active: speaker, icon: "speaker.wave.2.fill", label: String(localized: "扬声器")) {
                speaker.toggle()
                model.setSpeaker(speaker)
            }
            CallControlButton(active: false, icon: "circle.grid.3x3.fill", label: String(localized: "键盘")) {
                showKeypad = true
            }
            if conference == nil, supportsHold {
                CallControlButton(active: false, icon: "pause.circle.fill", label: String(localized: "保持")) {
                    group.holdActive()
                }
            }
            if conference == nil, !heldCalls.isEmpty {
                CallControlButton(active: false, icon: "person.2.fill", label: String(localized: "合并")) {
                    group.mergeHeldCalls()
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var supportsHold: Bool {
        switch call?.phase {
        case .active, .connecting, .reconnecting: return true
        default: return false
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        if call?.phase == .incomingRinging {
            HStack(spacing: 64) {
                Button {
                    model.hangup()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "phone.down.fill").font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(Color.red).clipShape(Circle())
                        Text(String(localized: "拒绝")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "拒绝来电"))
                Button {
                    model.answerCurrent()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "phone.fill").font(.title)
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(Color.green).clipShape(Circle())
                        Text(String(localized: "接听")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(localized: "接听来电"))
            }
            .padding(.bottom, 32)
        } else {
            VStack(spacing: 6) {
                Button {
                    model.hangup()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .accessibilityLabel(conference != nil ? String(localized: "结束会议") : String(localized: "挂断"))
                if conference != nil {
                    Text(String(localized: "结束会议")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 32)
        }
    }

    private var keypadSheet: some View {
        InCallKeypad { digit in
            if conference != nil {
                group.sendConferenceDTMF(digit, callId: selectedLegID)
            } else {
                model.playDTMF(digit)
            }
        }
        .presentationDetents([.medium])
    }

    private var statusText: String {
        guard let phase = call?.phase else { return "" }
        return phase.label
    }

    private var statusColor: Color {
        switch call?.phase {
        case .active: return .green
        case .failed: return .red
        case .reconnecting, .held: return .orange
        default: return .secondary
        }
    }
}

private struct CallControlButton: View {
    let active: Bool
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 60, height: 60)
                    .background(active ? Color.white : Color(.secondarySystemFill))
                    .foregroundStyle(active ? .black : .primary)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color(.separator), lineWidth: 0.5))
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

struct InCallKeypad: View {
    let onDigit: (String) -> Void
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]
    private let columns = Array(repeating: GridItem(.flexible()), count: 3)

    var body: some View {
        NavigationStack {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        // Bounded local feedback first, then the EXISTING
                        // remote DTMF exactly once (unchanged path). System
                        // sound touches no AVAudioSession, so the live call's
                        // audio ownership/graph/route is untouched.
                        KeypadTonePlayer.shared.play(key)
                        onDigit(key)
                    } label: {
                        Text(key)
                            .font(.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: 68, height: 68)
                            .background(Color(.secondarySystemFill))
                            .clipShape(Circle())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key)
                }
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 48)
            .navigationTitle("键盘")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { KeypadTonePlayer.shared.stop() }
        }
    }
}
