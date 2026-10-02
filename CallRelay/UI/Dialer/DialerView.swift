import SwiftUI

/// Native Phone-style keypad: generous whitespace, subtle circular keys with
/// normal digits and small letter captions, a single large green call button,
/// and a discreet gateway status line. No large title competes with the pad.
struct DialerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 8)

                DialStatusLine()
                    .padding(.bottom, 6)

                outgoingLinePicker

                Spacer(minLength: 2)

                TextField("", text: $number)
                    .keyboardType(.phonePad)
                    .multilineTextAlignment(.center)
                    .textContentType(.telephoneNumber)
                    .onChange(of: number) { _, value in
                        let filtered = String(value.filter { "0123456789+*#".contains($0) }.prefix(32))
                        if filtered != value { number = filtered }
                    }
                    .font(.system(size: 36, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(height: 46)
                    .overlay(alignment: .trailing) {
                        if !number.isEmpty {
                            Button {
                                number = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color(UIColor.tertiaryLabel))
                            }
                            .padding(.trailing, 24)
                            .accessibilityLabel("清空号码")
                        }
                    }
                    .accessibilityLabel(number.isEmpty ? "号码输入框" : number)

                if let match = contactMatch, !match.isEmpty {
                    Text(match)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text(" ")
                        .font(.subheadline)
                        .padding(.top, 2)
                }

                Spacer(minLength: 10)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(keys, id: \.self) { key in
                        DialKey(label: key) { append(key) }
                            .contextMenu {
                                if key == "0" { Button("输入 +") { append("+") } }
                            }
                    }
                }
                .padding(.horizontal, 64)

                Spacer(minLength: 16)

                HStack {
                    Color.clear.frame(width: 64, height: 64)
                    Spacer()
                    Button {
                        model.requestDial(number)
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(canDial ? Color.green : Color.gray.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .disabled(!canDial)
                    .accessibilityLabel("拨打")
                    Spacer()
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title2)
                            .foregroundStyle(number.isEmpty ? Color(UIColor.tertiaryLabel) : Color.primary)
                            .frame(width: 64, height: 64)
                    }
                    .disabled(number.isEmpty)
                    .accessibilityLabel("删除一位")
                }
                .padding(.horizontal, 52)
                .padding(.bottom, 10)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .alert("已按拦截规则阻止", isPresented: Binding(
                get: { model.blockedDialAttempt != nil },
                set: { if !$0 { model.blockedDialAttempt = nil } }
            )) {
                Button("知道了", role: .cancel) { model.blockedDialAttempt = nil }
            } message: {
                if let attempt = model.blockedDialAttempt {
                    Text("号码 \(attempt.peer) 命中：\(attempt.reason)。这是本机拦截，未通过网关呼出；可在短信/通话规则里修改。")
                }
            }
        }
    }

    private var canDial: Bool {
        !number.trimmingCharacters(in: .whitespaces).isEmpty
            && (!model.dialableLines.isEmpty || model.isDemo)
    }

    private var contactMatch: String? {
        guard !number.isEmpty else { return nil }
        return model.contacts.name(forPeer: number)
    }

    /// Phone-like current-SIM indicator; always shown when unified lines are
    /// known so the owner sees which number will call, even with one line.
    @ViewBuilder
    private var outgoingLinePicker: some View {
        if !model.authorizedLines.isEmpty {
            OutgoingLineMenu()
        }
    }

    private func append(_ key: String) {
        if number.count < 32 { number.append(key) }
    }
}

struct DialKey: View {
    let label: String
    let action: () -> Void

    private var subtitle: String {
        switch label {
        case "2": return "ABC"
        case "3": return "DEF"
        case "4": return "GHI"
        case "5": return "JKL"
        case "6": return "MNO"
        case "7": return "PQRS"
        case "8": return "TUV"
        case "9": return "WXYZ"
        case "0": return "+"
        default: return ""
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 32, weight: .regular))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            .background(Color(.tertiarySystemFill), in: Circle())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voiceOverKey)
    }

    private var voiceOverKey: String {
        label == "*" ? "星号" : label == "#" ? "井号" : label
    }
}

/// One discreet line: gateway state, never a dominant title.
struct DialStatusLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
            Text(model.linePhase.summaryLine)
                .font(.caption2)
                .lineLimit(1)
            if !model.gatewayName.isEmpty, !model.isDemo {
                Text("· \(model.gatewayName)").font(.caption2).lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityIdentifier("dialerStatus")
    }

    private var icon: String {
        switch model.linePhase {
        case .unpaired: return "slash.circle"
        case .demo: return "wand.and.stars"
        case .connecting: return "arrow.triangle.2.cyclepath"
        case .online: return "dot.radiowaves.left.and.right"
        case .offline: return "wifi.slash"
        }
    }

    private var color: Color {
        switch model.linePhase {
        case .online(let line):
            return line.registration == .registered ? .green : .orange
        case .demo: return .secondary
        case .offline, .unpaired: return .secondary
        case .connecting: return .orange
        }
    }
}
