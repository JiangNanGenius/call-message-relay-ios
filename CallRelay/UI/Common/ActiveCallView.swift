import SwiftUI

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @State private var muted = false
    @State private var speaker = false
    @State private var showKeypad = false

    private var call: ActiveCallViewState? { model.activeCall }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: model.isDemo ? "wand.and.stars" : "person.crop.circle.fill")
                    .resizable().scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(call?.peer ?? "未知")
                    .font(.system(size: 32, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(statusColor)

                if model.isDemo {
                    Text("演示模式")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15), in: Capsule())
                        .foregroundStyle(.purple)
                }

                if let quality = model.quality, !quality.summary.isEmpty {
                    Text(quality.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 48) {
                    CallControlButton(active: muted, icon: "mic.slash.fill", label: "静音") {
                        muted.toggle()
                        model.setMuted(muted)
                    }
                    CallControlButton(active: speaker, icon: "speaker.wave.2.fill", label: "扬声器") {
                        speaker.toggle()
                        model.setSpeaker(speaker)
                    }
                    CallControlButton(active: false, icon: "circle.grid.3x3.fill", label: "键盘") {
                        showKeypad = true
                    }
                }
                .padding(.bottom, 12)

                if call?.phase == .incomingRinging {
                    HStack(spacing: 64) {
                        Button {
                            model.hangup()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "phone.down.fill").font(.title)
                                    .foregroundStyle(.white)
                                    .frame(width: 72, height: 72).background(Color.red).clipShape(Circle())
                                Text("拒绝").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("拒绝来电")
                        Button {
                            model.answerCurrent()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "phone.fill").font(.title)
                                    .foregroundStyle(.white)
                                    .frame(width: 72, height: 72).background(Color.green).clipShape(Circle())
                                Text("接听").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("接听来电")
                    }
                    .padding(.bottom, 40)
                } else {
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
                    .accessibilityLabel("挂断")
                    .padding(.bottom, 40)
                }
            }
            .padding()
            .sheet(isPresented: $showKeypad) {
                InCallKeypad { digit in
                    model.playDTMF(digit)
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var statusText: String {
        guard let phase = call?.phase else { return "" }
        return phase.label
    }

    private var statusColor: Color {
        switch call?.phase {
        case .active: return .green
        case .failed: return .red
        case .reconnecting: return .orange
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
                        onDigit(key)
                    } label: {
                        Text(key)
                            .font(.title)
                            .frame(width: 68, height: 68)
                            .background(Color(.secondarySystemFill))
                            .clipShape(Circle())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key)
                }
            }
            .padding(.horizontal, 48)
            .navigationTitle("键盘")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
