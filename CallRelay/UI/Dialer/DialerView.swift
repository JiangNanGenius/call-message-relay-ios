import SwiftUI
import UIKit

/// Native Phone-style keypad: generous whitespace, subtle circular keys with
/// normal digits and small letter captions, a single large green call button,
/// and a discreet gateway status line. No large title competes with the pad.
struct DialerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var number = ""
    @State private var expandedContactID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    /// Keypad-fragment contact matches (compact rows above the pad). Never
    /// pops the system keyboard; selection fills the number like a dialed
    /// digit. Multi-number contacts expand to per-number rows first.
    private var suggestions: [ContactSuggestion] {
        ContactAutocomplete.suggestions(contacts: model.contacts.contacts, query: number, limit: 4)
    }

    private var showSuggestions: Bool {
        ContactSuggestionList.shouldShowSuggestions(suggestions: suggestions, query: number)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GatewayStateIndicator()
                    .padding(.top, 4)

                Spacer(minLength: 6)

                outgoingLinePicker

                Spacer(minLength: 2)

                DialNumberDisplay(number: $number)

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

                if showSuggestions {
                    ContactSuggestionList(
                        suggestions: suggestions,
                        expandedNumbers: expandedContactID.map {
                            ContactAutocomplete.numbers(for: $0, in: model.contacts.contacts)
                        },
                        onFill: { suggestion in
                            number = suggestion.phone
                            expandedContactID = nil
                        },
                        onExpand: { contactID in
                            expandedContactID = expandedContactID == contactID ? nil : contactID
                        }
                    )
                    .padding(.horizontal, 40)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            // Phone-like centered column on iPad/landscape; unchanged on
            // iPhone. On regular width the whole group is bounded vertically
            // so the number, keypad and call action stay together instead of
            // being spread across a huge empty pane.
            .frame(maxWidth: 460)
            .frame(maxHeight: horizontalSizeClass == .regular ? 700 : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Phone-like current-SIM indicator. Shown in live mode whenever a line
    /// exists, is being resolved, or the binding needs migration/re-pair, so
    /// a missing or unavailable number is explained instead of vanishing.
    @ViewBuilder
    private var outgoingLinePicker: some View {
        if model.shouldShowLinePicker {
            OutgoingLineMenu()
        }
        if !model.isDemo, model.authorizedLines.isEmpty,
           let status = model.lineListStatusMessage {
            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .accessibilityIdentifier("lineListStatus")
        }
    }

    private func append(_ key: String) {
        if number.count < 32 {
            number.append(key)
            expandedContactID = nil
        }
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

/// The dialer's own number display. Deliberately NOT a `TextField`: the
/// in-app keypad is the editor, so tapping the number must never summon the
/// system keyboard. A deliberate long-press still exposes the native
/// paste/copy menu, and accessibility keeps the value readable.
private struct DialNumberDisplay: View {
    @Binding var number: String

    var body: some View {
        Text(number.isEmpty ? " " : number)
            .font(.system(size: 36, weight: .regular))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    pasteFromPasteboard()
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .disabled(pasteboardText == nil)
                Button {
                    UIPasteboard.general.string = number
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                }
                .disabled(number.isEmpty)
            }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(number.isEmpty ? "号码" : number)
            .accessibilityHint("长按可粘贴或拷贝")
    }

    private var pasteboardText: String? {
        guard let raw = UIPasteboard.general.string else { return nil }
        return String(raw.filter { "0123456789+*#".contains($0) }.prefix(32))
    }

    private func pasteFromPasteboard() {
        guard let filtered = pasteboardText, !filtered.isEmpty else { return }
        number = filtered
    }
}

/// One unobtrusive gateway-connection state at the top of the dialer. It never
/// doubles as a cellular-signal indicator (a connected gateway is not a
/// registered SIM), and it omits operator/registered/engineering detail.
/// Genuine disconnects and errors keep their actionable message.
struct GatewayStateIndicator: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("dialerStatus")
    }

    private var text: String {
        switch model.linePhase {
        case .unpaired: return "未配对网关"
        case .demo: return "演示模式"
        case .connecting: return "正在连接网关…"
        case .online(let line):
            switch line.registration {
            case .registered: return "已连接"
            case .searching: return "正在搜索网络…"
            case .denied: return "网络注册被拒绝"
            case .unknown: return "网络状态未知"
            }
        case .offline(let message): return message
        }
    }

    private var dotColor: Color {
        switch model.linePhase {
        case .online(let line):
            return line.registration == .registered ? .green.opacity(0.85) : .orange
        case .connecting: return .orange
        case .offline, .unpaired, .demo: return .secondary
        }
    }
}
