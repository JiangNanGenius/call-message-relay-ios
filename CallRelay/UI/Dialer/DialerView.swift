import SwiftUI
import UIKit

/// Native Phone-style keypad with FIXED geometry: the number, SIM selector,
/// keypad and call controls never move when suggestions appear or disappear
/// (the 2026-10-04 field complaint: the growing inline suggestion list pushed
/// the keypad and green call button under the tab bar). Matches present at
/// most one compact two-row panel — ONE best candidate plus an
/// "其他 N 个结果" row that opens a sheet with the full list. Overflow lives
/// in the sheet, never on the page.
struct DialerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var number = ""
    @State private var showsResultsSheet = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    /// ALL matches (uncapped) so the inline "其他 N 个结果" count is honest
    /// and the results sheet can reach every contact — the cached pinyin/T9
    /// index keeps per-keystroke full scans cheap.
    private var allSuggestions: [ContactSuggestion] {
        model.contacts.searchContacts(query: number, limit: 0)
    }

    private var showSuggestions: Bool {
        ContactSuggestionList.shouldShowSuggestions(suggestions: allSuggestions, query: number)
    }

    /// The fixed-height suggestion slot (2 rows). Reserving it keeps the
    /// keypad pinned whether or not matches exist.
    private let suggestionSlotHeight: CGFloat = 104

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GatewayStateIndicator()
                    .padding(.top, 4)

                Spacer(minLength: 6)

                outgoingLinePicker

                Spacer(minLength: 2)

                DialNumberDisplay(number: $number)

                // The suggestion slot ALWAYS occupies its fixed height
                // (clear placeholder) so the keypad and call controls never
                // move when matches appear or disappear.
                ZStack(alignment: .top) {
                    Color.clear
                    suggestionPanel
                }
                .frame(height: suggestionSlotHeight)
                .padding(.top, 6)

                Spacer(minLength: 10)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(keys, id: \.self) { key in
                        DialKey(label: key) {
                            // Native Phone-style local key feedback; system
                            // sound policy only, no audio session is touched.
                            KeypadTonePlayer.shared.play(key)
                            append(key)
                        }
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
            .sheet(isPresented: $showsResultsSheet) {
                DialerResultsSheet(
                    query: number,
                    suggestions: allSuggestions,
                    contacts: model.contacts.contacts,
                    onFill: { suggestion in
                        number = suggestion.phone
                        showsResultsSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
            }
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
            .onDisappear { KeypadTonePlayer.shared.stop() }
        }
    }

    /// Compact two-row panel: row 1 = best candidate (tap fills; a
    /// multi-number contact opens the sheet so a number is chosen
    /// explicitly), row 2 = "其他 N 个结果" opening the sheet.
    @ViewBuilder
    private var suggestionPanel: some View {
        if showSuggestions, let best = allSuggestions.first {
            VStack(spacing: 0) {
                BestMatchRow(suggestion: best) {
                    if best.hasMultipleNumbers {
                        showsResultsSheet = true
                    } else {
                        number = best.phone
                    }
                }
                if allSuggestions.count > 1 {
                    Divider().padding(.leading, 52)
                    Button {
                        showsResultsSheet = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("其他 \(allSuggestions.count - 1) 个结果")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("dialerMoreResults")
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 40)
            .transition(.opacity)
        }
    }

    private var canDial: Bool {
        !number.trimmingCharacters(in: .whitespaces).isEmpty
            && (!model.dialableLines.isEmpty || model.isDemo)
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
        }
    }
}

/// The single best candidate row (avatar + name + labeled number). Explicit
/// per-number choice for multi-number contacts happens in the results sheet.
private struct BestMatchRow: View {
    let suggestion: ContactSuggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(.systemGray3))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(suggestion.name.first.map(String.init) ?? "?")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(suggestion.hasMultipleNumbers
                         ? String(localized: "多个号码，点选其中一个")
                         : suggestion.labeledPhone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if suggestion.hasMultipleNumbers {
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dialerBestMatch")
        .accessibilityHint(suggestion.hasMultipleNumbers
                           ? "该联系人有多个号码"
                           : "使用号码 \(suggestion.phone)")
    }
}

/// Full suggestion list presented as a sheet so overflow never affects the
/// dialer page geometry. Reuses the shared multi-number expansion: a number
/// is only ever filled by an explicit per-number choice.
private struct DialerResultsSheet: View {
    let query: String
    let suggestions: [ContactSuggestion]
    let contacts: [ContactItem]
    let onFill: (ContactSuggestion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expandedContactID: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(suggestions) { suggestion in
                    if suggestion.hasMultipleNumbers {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedContactID == suggestion.contactID },
                            set: { expandedContactID = $0 ? suggestion.contactID : nil }
                        )) {
                            ForEach(ContactAutocomplete.numbers(for: suggestion.contactID, in: contacts)) { number in
                                Button {
                                    onFill(number)
                                } label: {
                                    HStack {
                                        Text(number.labeledPhone)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                            }
                        } label: {
                            rowLabel(suggestion)
                        }
                    } else {
                        Button {
                            onFill(suggestion)
                        } label: {
                            rowLabel(suggestion)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(query.isEmpty ? String(localized: "联系人") : query)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func rowLabel(_ suggestion: ContactSuggestion) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(.systemGray3))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(suggestion.name.first.map(String.init) ?? "?")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.name).font(.body).lineLimit(1)
                Text(suggestion.hasMultipleNumbers
                     ? String(localized: "多个号码，点选其中一个")
                     : suggestion.labeledPhone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
        HStack(spacing: 2) {
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 36, weight: .regular))
                .monospacedDigit()
                .lineLimit(1)
                // Shrink-to-fit inside the REAL layout budget that remains
                // after the clear button's reserved slot, so long numbers
                // can never run under the clear action.
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 46)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(number.isEmpty ? "号码" : number)
            if !number.isEmpty {
                Button {
                    number = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color(UIColor.tertiaryLabel))
                        .frame(width: 28, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空号码")
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .contentShape(Rectangle())
        .accessibilityIdentifier("dialerNumberDisplay")
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
